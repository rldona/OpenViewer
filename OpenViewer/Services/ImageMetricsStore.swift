import Foundation
import UIKit

/// What the grid needs to know about an image before decoding it.
struct ImageMetrics: Equatable {
    /// Width / height, clamped to a range the grid can display.
    var ratio: CGFloat
    /// Longest side in pixels (0 when the file could not be read).
    var maxSide: Int
}

/// Persistent cache of image metrics, so the justified grid and the minimum-size filter work
/// instantly the second time a folder is opened. Thread-safe.
final class ImageMetricsStore {
    static let shared = ImageMetricsStore()

    /// Ratio used while the real one is still unknown.
    static let placeholderRatio: CGFloat = 4.0 / 3.0

    /// Path → [ratio, maxSide].
    private var entries: [String: [Float]] = [:]
    private var dirty = false
    private let lock = NSLock()
    private let fileURL: URL?
    private let saveQueue = DispatchQueue(label: "openviewer.metrics", qos: .utility)

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        fileURL = caches?.appendingPathComponent("OpenViewer/image-metrics.bin")
        if let fileURL, let data = try? Data(contentsOf: fileURL), let stored = Self.decode(data) {
            entries = stored
        } else if let legacy = caches?.appendingPathComponent("OpenViewer/image-metrics.plist"),
                  let data = try? Data(contentsOf: legacy),
                  let stored = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: [Float]] {
            // Earlier versions stored a property list.
            entries = stored
            dirty = true
            try? FileManager.default.removeItem(at: legacy)
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                               object: nil, queue: nil) { [weak self] _ in self?.save() }
    }

    /// Metrics for many files under a single lock (filtering big lists).
    func metrics(for urls: [URL]) -> [ImageMetrics?] {
        let keys = urls.map { PathKey.make($0.path) }
        lock.lock()
        defer { lock.unlock() }
        return keys.map { key in
            guard let values = entries[key], values.count == 2 else { return nil }
            return ImageMetrics(ratio: CGFloat(values[0]), maxSide: Int(values[1]))
        }
    }

    func metrics(for url: URL) -> ImageMetrics? {
        lock.lock()
        defer { lock.unlock() }
        guard let values = entries[PathKey.make(url.path)], values.count == 2 else { return nil }
        return ImageMetrics(ratio: CGFloat(values[0]), maxSide: Int(values[1]))
    }

    func set(_ metrics: ImageMetrics, for url: URL) {
        lock.lock()
        entries[PathKey.make(url.path)] = [Float(metrics.ratio), Float(metrics.maxSide)]
        dirty = true
        lock.unlock()
    }

    /// Reads the metrics from the file header only (no pixel decoding).
    static func read(_ url: URL) -> ImageMetrics {
        guard let size = ImagePipeline.pixelSize(of: url), size.width > 0, size.height > 0 else {
            return ImageMetrics(ratio: 1, maxSide: 0)
        }
        return ImageMetrics(ratio: clamp(size.width / size.height), maxSide: Int(max(size.width, size.height)))
    }

    /// Keeps extreme panoramas and slivers usable in the grid.
    static func clamp(_ ratio: CGFloat) -> CGFloat {
        min(max(ratio, 0.25), 10)
    }

    func save() {
        lock.lock()
        guard dirty, let fileURL else { lock.unlock(); return }
        let snapshot = entries
        dirty = false
        lock.unlock()
        saveQueue.async {
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Self.encode(snapshot).write(to: fileURL, options: .atomic)
        }
    }

    private static let magic = "OVIM"

    static func encode(_ entries: [String: [Float]]) -> Data {
        var writer = BinaryWriter(magic: magic, version: 1)
        let valid = entries.filter { $0.value.count == 2 }
        writer.writeCount(valid.count)
        for (key, values) in valid {
            writer.write(key)
            writer.write(values[0])
            writer.write(values[1])
        }
        return writer.data
    }

    static func decode(_ data: Data) -> [String: [Float]]? {
        guard var reader = BinaryReader(data: data, magic: magic, version: 1) else { return nil }
        let count = reader.readCount()
        var entries: [String: [Float]] = [:]
        entries.reserveCapacity(count)
        for _ in 0..<count {
            let key = reader.readString()
            entries[key] = [reader.readFloat(), reader.readFloat()]
        }
        return reader.isValid ? entries : nil
    }
}

/// Reads unknown image metrics in the background, prioritised items first, and signals the main
/// queue in batches. Results are written straight to `ImageMetricsStore`.
final class MetricsResolver {
    private let urls: [URL]
    private var handedOut: [Bool] = []
    private var cursor = 0
    private var priority: Range<Int>?
    private var pendingCount = 0
    private var lastFlush = CFAbsoluteTimeGetCurrent()
    private var cancelled = false
    private let lock = NSLock()
    private let onBatch: () -> Void

    init(urls: [URL], onBatch: @escaping () -> Void) {
        self.urls = urls
        self.onBatch = onBatch
    }

    /// Everything, including checking which items are already cached, runs off the main thread.
    func start(workers: Int = 4) {
        DispatchQueue.global(qos: .utility).async { [self] in
            let store = ImageMetricsStore.shared
            let known = urls.map { store.metrics(for: $0) != nil }
            lock.lock()
            handedOut = known
            let isCancelled = cancelled
            lock.unlock()
            guard !isCancelled, known.contains(false) else { return }
            spawn(workers: workers)
        }
    }

    private func spawn(workers: Int) {
        let group = DispatchGroup()
        for _ in 0..<workers {
            DispatchQueue.global(qos: .utility).async(group: group) { [self] in
                while let index = next() {
                    ImageMetricsStore.shared.set(ImageMetricsStore.read(urls[index]), for: urls[index])
                    recordOne()
                }
            }
        }
        group.notify(queue: .global(qos: .utility)) { [self] in
            flush(force: true)
            ImageMetricsStore.shared.save()
        }
    }

    /// Visible items jump the queue.
    func prioritize(_ range: Range<Int>) {
        lock.lock()
        priority = range.clamped(to: 0..<urls.count)
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    private func next() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return nil }
        if let range = priority?.clamped(to: 0..<handedOut.count) {
            if let index = range.first(where: { !handedOut[$0] }) {
                handedOut[index] = true
                return index
            }
            priority = nil
        }
        while cursor < handedOut.count {
            let index = cursor
            cursor += 1
            if !handedOut[index] {
                handedOut[index] = true
                return index
            }
        }
        return nil
    }

    private func recordOne() {
        lock.lock()
        pendingCount += 1
        lock.unlock()
        flush(force: false)
    }

    private func flush(force: Bool) {
        lock.lock()
        let now = CFAbsoluteTimeGetCurrent()
        guard !cancelled, pendingCount > 0, force || now - lastFlush > 0.3 else { lock.unlock(); return }
        pendingCount = 0
        lastFlush = now
        lock.unlock()
        DispatchQueue.main.async { [self] in
            lock.lock()
            let isCancelled = cancelled
            lock.unlock()
            if !isCancelled { onBatch() }
        }
    }
}
