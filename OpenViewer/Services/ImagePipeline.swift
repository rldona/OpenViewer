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
        var diskKey: String { "\(maxPixel)|\(fileSize)|\(modified.timeIntervalSince1970)|\(PathKey.make(url.path))" }
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
            let root = caches.appendingPathComponent("OpenViewer", isDirectory: true)
            let dir = root.appendingPathComponent("\(name)-v\(Self.diskFormatVersion)", isDirectory: true)
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

    /// Deletes caches written by earlier versions (v1 stored lossy JPEGs without transparency) and
    /// files that are no longer used. Called once at launch.
    static func removeLegacyCaches() {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let root = caches.appendingPathComponent("OpenViewer", isDirectory: true)
        var legacy = ["thumbnails", "aspect-ratios.plist"]
        legacy += (1..<diskFormatVersion).map { "thumbnails-v\($0)" }
        DispatchQueue.global(qos: .background).async {
            for name in legacy { try? FileManager.default.removeItem(at: root.appendingPathComponent(name)) }
        }
    }

    /// Removes this pipeline's disk cache folder entirely (tests).
    func removeDiskCache() {
        guard let dir = diskDirectory else { return }
        try? FileManager.default.removeItem(at: dir)
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
        let diskURL = diskDirectory.map { $0.appendingPathComponent(Self.hash(request.diskKey) + ".thumb") }
        if let diskURL, FileManager.default.fileExists(atPath: diskURL.path), let cached = Self.decodeFully(diskURL) {
            return UIImage(cgImage: cached)
        }
        guard let cg = Self.downsample(request.url, maxPixel: request.maxPixel) else { return nil }
        if let diskURL {
            diskQueue.async { Self.writeThumbnail(cg, to: diskURL) }
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
           max(embedded.width, embedded.height) >= maxPixel {
            // Only when it is at least as large as requested: an embedded preview is never upscaled.
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

    /// Bump when the on-disk thumbnail format changes; older caches are deleted.
    static let diskFormatVersion = 2

    /// Images with transparency are stored as lossless PNG (JPEG/HEIC would lose the alpha channel).
    /// Opaque ones use HEIC at 0.95: measured at ~54 dB PSNR on line art and ~41 dB on photos
    /// against a fresh decode (visually lossless), at a fraction of PNG's size. JPEG is the fallback.
    private static func writeThumbnail(_ image: CGImage, to url: URL) {
        if hasAlpha(image) {
            encode(image, as: .png, quality: nil, to: url)
        } else if !encode(image, as: .heic, quality: 0.95, to: url) {
            encode(image, as: .jpeg, quality: 0.95, to: url)
        }
    }

    @discardableResult
    private static func encode(_ image: CGImage, as type: UTType, quality: Double?, to url: URL) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else { return false }
        let options: [CFString: Any] = quality.map { [kCGImageDestinationLossyCompressionQuality: $0] } ?? [:]
        CGImageDestinationAddImage(dest, image, options as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }

    static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }

    private static func hash(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
