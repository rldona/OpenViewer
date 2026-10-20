import CryptoKit
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Handle returned by `ImagePipeline.load`; pass it to `cancel` when the result is no longer needed.
final class LoadToken {
    fileprivate let key: String
    fileprivate let id = UUID()
    fileprivate init(key: String) { self.key = key }
}

/// Downsampling image loader with a memory cache, an optional disk cache, request coalescing,
/// priorities and cancellation. Completions are always delivered on the main queue.
final class ImagePipeline {
    struct Request {
        let url: URL
        let maxPixel: Int
        var modified: Date = .distantPast
        var fileSize: Int = 0

        init(url: URL, maxPixel: Int, modified: Date = .distantPast, fileSize: Int = 0) {
            self.url = url
            self.maxPixel = maxPixel
            self.modified = modified
            self.fileSize = fileSize
        }

        init(_ item: ImageItem, maxPixel: Int) {
            self.init(url: item.url, maxPixel: maxPixel, modified: item.modified, fileSize: item.size)
        }

        var memoryKey: String { "\(maxPixel)|\(url.path)" }
        var diskKey: String { "\(maxPixel)|\(fileSize)|\(modified.timeIntervalSince1970)|\(url.path)" }
    }

    /// Grid thumbnails: persisted on disk so revisiting a folder is instant.
    static let thumbnails = ImagePipeline(name: "thumbnails", diskCache: true,
                                          memoryLimit: 200 << 20, concurrency: ProcessInfo.processInfo.activeProcessorCount)
    /// Screen-sized images for the viewer.
    static let screen = ImagePipeline(name: "screen", diskCache: false, memoryLimit: 250 << 20, concurrency: 3)

    static let thumbnailBuckets = [256, 512, 768, 1024, 1536, 2048]

    /// Thumbnail sizes are bucketed so changing the grid size reuses cached images.
    static func thumbnailBucket(forPixels pixels: CGFloat) -> Int {
        thumbnailBuckets.first { CGFloat($0) >= pixels } ?? thumbnailBuckets.last!
    }

    private final class Entry {
        let operation: BlockOperation
        var waiters: [UUID: (UIImage?) -> Void] = [:]
        init(operation: BlockOperation) { self.operation = operation }
    }

    private let memory = NSCache<NSString, UIImage>()
    private let queue = OperationQueue()
    private let diskQueue = DispatchQueue(label: "openviewer.diskcache", qos: .utility)
    private let diskDirectory: URL?
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]

    init(name: String, diskCache: Bool, memoryLimit: Int, concurrency: Int) {
        memory.totalCostLimit = memoryLimit
        queue.name = "openviewer.\(name)"
        queue.maxConcurrentOperationCount = max(2, concurrency)
        queue.qualityOfService = .userInitiated
        if diskCache, let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let dir = caches.appendingPathComponent("OpenViewer/\(name)", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            diskDirectory = dir
        } else {
            diskDirectory = nil
        }
    }

    // MARK: Public API

    func cachedImage(for request: Request) -> UIImage? {
        memory.object(forKey: request.memoryKey as NSString)
    }

    /// Returns `nil` when the image was served synchronously from memory (the completion has already run).
    @discardableResult
    func load(_ request: Request,
              priority: Operation.QueuePriority = .normal,
              completion: @escaping (UIImage?) -> Void) -> LoadToken? {
        let key = request.memoryKey
        if let image = memory.object(forKey: key as NSString) {
            completion(image)
            return nil
        }
        let token = LoadToken(key: key)

        lock.lock()
        defer { lock.unlock() }
        if let entry = entries[key] {
            entry.waiters[token.id] = completion
            if priority.rawValue > entry.operation.queuePriority.rawValue {
                entry.operation.queuePriority = priority
            }
            return token
        }

        let operation = BlockOperation()
        operation.queuePriority = priority
        operation.addExecutionBlock { [weak self, unowned operation] in
            guard let self, !operation.isCancelled else { return }
            let image = self.produce(request)
            self.finish(key: key, image: image)
        }
        let entry = Entry(operation: operation)
        entry.waiters[token.id] = completion
        entries[key] = entry
        queue.addOperation(operation)
        return token
    }

    /// Warms the cache without a caller-visible result.
    @discardableResult
    func prefetch(_ request: Request) -> LoadToken? {
        load(request, priority: .low) { _ in }
    }

    func cancel(_ token: LoadToken?) {
        guard let token else { return }
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[token.key] else { return }
        entry.waiters[token.id] = nil
        if entry.waiters.isEmpty {
            entry.operation.cancel()
            entries[token.key] = nil
        }
    }

    /// Lets tests enqueue work deterministically.
    var queueSuspendedForTesting: Bool {
        get { queue.isSuspended }
        set { queue.isSuspended = newValue }
    }

    func clearMemory() {
        memory.removeAllObjects()
    }

    func clearDisk() {
        guard let dir = diskDirectory else { return }
        diskQueue.async {
            try? FileManager.default.removeItem(at: dir)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    // MARK: Pipeline

    private func finish(key: String, image: UIImage?) {
        if let image, let cg = image.cgImage {
            memory.setObject(image, forKey: key as NSString, cost: cg.bytesPerRow * cg.height)
        }
        lock.lock()
        let waiters = entries.removeValue(forKey: key)?.waiters.values.map { $0 } ?? []
        lock.unlock()
        guard !waiters.isEmpty else { return }
        DispatchQueue.main.async {
            waiters.forEach { $0(image) }
        }
    }

    private func produce(_ request: Request) -> UIImage? {
        let diskURL = diskDirectory.map { $0.appendingPathComponent(Self.hash(request.diskKey) + ".jpg") }
        if let diskURL, FileManager.default.fileExists(atPath: diskURL.path), let cached = Self.decodeFully(diskURL) {
            return UIImage(cgImage: cached)
        }
        guard let cg = Self.downsample(request.url, maxPixel: request.maxPixel) else { return nil }
        if let diskURL {
            diskQueue.async { Self.writeJPEG(cg, to: diskURL) }
        }
        return UIImage(cgImage: cg)
    }

    // MARK: ImageIO helpers

    /// Decodes `url` so that its longest side is at most `maxPixel`, never decoding the full
    /// bitmap when it can be avoided. Embedded previews (EXIF thumbnails, RAW previews) are used
    /// when they are large enough, which is dramatically faster for camera files.
    static func downsample(_ url: URL, maxPixel: Int) -> CGImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }

        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
        ]
        if let embedded = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
           max(embedded.width, embedded.height) >= maxPixel * 3 / 4 {
            return embedded
        }
        options[kCGImageSourceCreateThumbnailFromImageIfAbsent] = nil
        options[kCGImageSourceCreateThumbnailFromImageAlways] = true
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    static func decodeFully(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    /// Pixel size of the first frame, oriented, read from the header only.
    static func pixelSize(of url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        let orientation = props[kCGImagePropertyOrientation] as? UInt32 ?? 1
        return orientation >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    private static func writeJPEG(_ image: CGImage, to url: URL) {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        CGImageDestinationFinalize(dest)
    }

    private static func hash(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
