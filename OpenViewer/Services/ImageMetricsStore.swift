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
        fileURL = caches?.appendingPathComponent("OpenViewer/image-metrics.plist")
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let stored = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: [Float]] {
            entries = stored
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                               object: nil, queue: nil) { [weak self] _ in self?.save() }
    }

    func metrics(for url: URL) -> ImageMetrics? {
        lock.lock()
        defer { lock.unlock() }
        guard let values = entries[url.path], values.count == 2 else { return nil }
        return ImageMetrics(ratio: CGFloat(values[0]), maxSide: Int(values[1]))
    }

    func set(_ metrics: ImageMetrics, for url: URL) {
        lock.lock()
        entries[url.path] = [Float(metrics.ratio), Float(metrics.maxSide)]
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
            guard let data = try? PropertyListSerialization.data(fromPropertyList: snapshot, format: .binary, options: 0) else { return }
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

/// Reads unknown image metrics in the background, prioritised items first, and signals the main
/// queue in batches. Results are written straight to `ImageMetricsStore`.
final class MetricsResolver {
    private let urls: [URL]
    private var handedOut: [Bool]
    private var cursor = 0
    private var priority: Range<Int>?
    private var pendingCount = 0
    private var lastFlush = CFAbsoluteTimeGetCurrent()
    private var cancelled = false
    private let lock = NSLock()
    private let onBatch: () -> Void

    /// `known[i]` is true when `urls[i]` already has metrics in the store.
    init(urls: [URL], known: [Bool], onBatch: @escaping () -> Void) {
        self.urls = urls
        self.handedOut = known
        self.onBatch = onBatch
    }

    func start(workers: Int = 4) {
        guard handedOut.contains(false) else { return }
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
        if let range = priority {
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
