import Foundation
import UIKit

/// Persistent cache of image aspect ratios (width / height), so the justified grid can lay out
/// a folder instantly the second time it is opened. Thread-safe.
final class AspectRatioStore {
    static let shared = AspectRatioStore()

    /// Ratio used while the real one is still unknown.
    static let placeholder: CGFloat = 4.0 / 3.0

    private var ratios: [String: Float] = [:]
    private var dirty = false
    private let lock = NSLock()
    private let fileURL: URL?
    private let saveQueue = DispatchQueue(label: "openviewer.aspects", qos: .utility)

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        fileURL = caches?.appendingPathComponent("OpenViewer/aspect-ratios.plist")
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let stored = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Float] {
            ratios = stored
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                               object: nil, queue: nil) { [weak self] _ in self?.save() }
    }

    func ratio(for url: URL) -> CGFloat? {
        lock.lock()
        defer { lock.unlock() }
        return ratios[url.path].map { CGFloat($0) }
    }

    func set(_ ratio: CGFloat, for url: URL) {
        lock.lock()
        ratios[url.path] = Float(ratio)
        dirty = true
        lock.unlock()
    }

    /// Reads the ratio from the file header only (no pixel decoding).
    static func readRatio(of url: URL) -> CGFloat {
        guard let size = ImagePipeline.pixelSize(of: url), size.width > 0, size.height > 0 else { return 1 }
        return clamp(size.width / size.height)
    }

    /// Keeps extreme panoramas and slivers usable in the grid.
    static func clamp(_ ratio: CGFloat) -> CGFloat {
        min(max(ratio, 0.25), 10)
    }

    func save() {
        lock.lock()
        guard dirty, let fileURL else { lock.unlock(); return }
        let snapshot = ratios
        dirty = false
        lock.unlock()
        saveQueue.async {
            guard let data = try? PropertyListSerialization.data(fromPropertyList: snapshot, format: .binary, options: 0) else { return }
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

/// Resolves unknown aspect ratios in the background, visible items first, and reports them in
/// batches on the main queue.
final class AspectResolver {
    private let urls: [URL]
    private var handedOut: [Bool]
    private var cursor = 0
    private var priority: Range<Int>?
    private var pending: [(Int, CGFloat)] = []
    private var lastFlush = CFAbsoluteTimeGetCurrent()
    private var cancelled = false
    private let lock = NSLock()
    private let onBatch: ([(index: Int, ratio: CGFloat)]) -> Void

    /// `known[i]` is true when item `i` already has a ratio.
    init(urls: [URL], known: [Bool], onBatch: @escaping ([(index: Int, ratio: CGFloat)]) -> Void) {
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
                    let ratio = AspectRatioStore.readRatio(of: urls[index])
                    AspectRatioStore.shared.set(ratio, for: urls[index])
                    record(index, ratio)
                }
            }
        }
        group.notify(queue: .global(qos: .utility)) { [self] in
            flush(force: true)
            AspectRatioStore.shared.save()
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

    private func record(_ index: Int, _ ratio: CGFloat) {
        lock.lock()
        pending.append((index, ratio))
        lock.unlock()
        flush(force: false)
    }

    private func flush(force: Bool) {
        lock.lock()
        let now = CFAbsoluteTimeGetCurrent()
        guard !cancelled, !pending.isEmpty, force || now - lastFlush > 0.3 else { lock.unlock(); return }
        let batch = pending.map { (index: $0.0, ratio: $0.1) }
        pending.removeAll()
        lastFlush = now
        lock.unlock()
        DispatchQueue.main.async { [self] in
            lock.lock()
            let isCancelled = cancelled
            lock.unlock()
            if !isCancelled { onBatch(batch) }
        }
    }
}
