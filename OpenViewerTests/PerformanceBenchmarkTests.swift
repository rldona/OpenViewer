import ImageIO
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import OpenViewer

/// Rough timings of the hot paths (thumbnail decode, disk cache, persisted stores). They print
/// numbers to compare before and after a change; the assertions only catch gross regressions.
final class PerformanceBenchmarkTests: XCTestCase {
    private static var root: URL = {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ov-bench", isDirectory: true)
        let marker = root.appendingPathComponent(".ready-v1")
        if !FileManager.default.fileExists(atPath: marker.path) {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for index in 0..<120 { writeImage(root.appendingPathComponent("sprite\(index).png"), side: 420, alpha: true, seed: index) }
            for index in 0..<30 { writeImage(root.appendingPathComponent("photo\(index).jpg"), side: 3000, alpha: false, seed: index) }
            FileManager.default.createFile(atPath: marker.path, contents: Data())
        }
        return root
    }()

    private static func writeImage(_ url: URL, side: Int, alpha: Bool, seed: Int) {
        let height = side * 2 / 3
        let context = CGContext(data: nil, width: side, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: (alpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue)!
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<60 {
            context.setFillColor(red: .random(in: 0...1, using: &generator), green: .random(in: 0...1, using: &generator),
                                 blue: .random(in: 0...1, using: &generator), alpha: 1)
            let w = CGFloat.random(in: 10...CGFloat(side) / 3), h = CGFloat.random(in: 10...CGFloat(height) / 3)
            context.fillEllipse(in: CGRect(x: .random(in: 0...CGFloat(side) - w), y: .random(in: 0...CGFloat(height) - h), width: w, height: h))
        }
        let type = alpha ? UTType.png : .jpeg
        let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        CGImageDestinationFinalize(destination)
    }

    private var urls: [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: Self.root, includingPropertiesForKeys: nil)) ?? [])
            .filter { ImageTypes.isImage($0) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func time(_ label: String, _ block: () -> Void) -> Double {
        let start = CFAbsoluteTimeGetCurrent()
        block()
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
        print("⏱ \(label): \(String(format: "%.1f", ms)) ms")
        return ms
    }

    private func loadAll(_ pipeline: ImagePipeline, _ urls: [URL], maxPixel: Int) {
        let group = DispatchGroup()
        for url in urls {
            group.enter()
            pipeline.load(.init(url: url, maxPixel: maxPixel)) { image in
                XCTAssertNotNil(image)
                group.leave()
            }
        }
        while group.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.002)) }
    }

    func testThumbnailThroughput() {
        let urls = self.urls
        let sprites = urls.filter { $0.pathExtension == "png" }
        let photos = urls.filter { $0.pathExtension == "jpg" }
        let pipeline = ImagePipeline(name: "bench-\(UUID().uuidString)", diskCache: true, memoryLimit: 400 << 20,
                                     concurrency: ProcessInfo.processInfo.activeProcessorCount)
        defer { pipeline.removeDiskCache() }
        let coldSprites = time("cold: \(sprites.count) small PNG sprites @512") { loadAll(pipeline, sprites, maxPixel: 512) }
        _ = time("cold: \(photos.count) 3000px JPEG photos @512") { loadAll(pipeline, photos, maxPixel: 512) }
        pipeline.waitForDiskWritesForTesting()
        pipeline.clearMemory()
        _ = time("disk: \(sprites.count) sprites") { loadAll(pipeline, sprites, maxPixel: 512) }
        pipeline.clearMemory()
        _ = time("disk: \(photos.count) photos") { loadAll(pipeline, photos, maxPixel: 512) }
        _ = time("memory: all") { loadAll(pipeline, urls, maxPixel: 512) }
        let decoded = sprites.compactMap { ImagePipeline.downsample($0, maxPixel: 512) }
        print("⏱ sprite thumbnail format: \(decoded.first.map { "\($0.bitsPerPixel) bpp, alpha \($0.alphaInfo.rawValue), \($0.colorSpace?.name ?? "?" as CFString)" } ?? "-")")
        _ = time("preparingForDisplay \(decoded.count) sprites") {
            DispatchQueue.concurrentPerform(iterations: decoded.count) { _ = UIImage(cgImage: decoded[$0]).preparingForDisplay() }
        }
        XCTAssertLessThan(coldSprites, 20_000)
    }

    func testScanSnapshotRoundTrip() {
        var snapshot = ScanSnapshot()
        for folder in 0..<1_000 {
            snapshot.directories["folder \(folder)"] = ScanSnapshot.Directory(
                modified: 1_700_000_000, subdirectories: [],
                files: (0..<100).map { ScanSnapshot.File(name: "image_\($0)_of_folder_\(folder).png", size: 123_456, modified: 1_700_000_000) })
        }
        snapshot.directories[""] = ScanSnapshot.Directory(modified: 1, subdirectories: (0..<1_000).map { "folder \($0)" }, files: [])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bench-root-\(UUID().uuidString)")
        defer { ScanCache.remove(root: root) }
        _ = time("scan snapshot save (100k files)") { ScanCache.save(snapshot, root: root) }
        var loaded: ScanSnapshot?
        _ = time("scan snapshot load (100k files)") { loaded = ScanCache.load(root: root) }
        XCTAssertEqual(loaded?.directories.count, 1_001)
        XCTAssertEqual(loaded?.images(root: root).count, 100_000)
    }

    func testAnalysisStoreLoad() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("bench-analysis-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: file) }
        let writer = ImageAnalysisStore(fileURL: file)
        let start = CFAbsoluteTimeGetCurrent()
        defer { print("⏱ analysis store 20k updates: \(Int((CFAbsoluteTimeGetCurrent() - start) * 1000)) ms (incl. save)") }
        for index in 0..<20_000 {
            let item = ImageItem(url: URL(fileURLWithPath: "/bench/image\(index).png"), size: 1000, modified: Date(timeIntervalSince1970: 1))
            writer.update(item) {
                $0.palette = [0xFF0000, 0x00FF00, 0x0000FF, 0x123456, 0x654321]
                $0.weights = [0.4, 0.2, 0.2, 0.1, 0.1]
                $0.hash = UInt64(index)
                $0.vhash = UInt64(index * 7)
                $0.families = 3
            }
        }
        writer.saveNowForTesting()
        let reader = ImageAnalysisStore(fileURL: file)
        var record: ImageAnalysisRecord?
        _ = time("analysis store load (20k records)") {
            record = reader.record(for: ImageItem(url: URL(fileURLWithPath: "/bench/image5.png"), size: 1000,
                                                  modified: Date(timeIntervalSince1970: 1)))
        }
        XCTAssertEqual(record?.hash, 5)
        XCTAssertEqual(record?.weights?.first ?? 0, 0.4, accuracy: 0.0001)
    }

    /// Decode cost of each disk-cache format for the same 512 px thumbnails.
    func testDiskFormatDecode() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bench-formats-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let photos = urls.filter { $0.pathExtension == "jpg" }.compactMap { ImagePipeline.downsample($0, maxPixel: 512) }
        let sprites = urls.filter { $0.pathExtension == "png" }.prefix(30).compactMap { ImagePipeline.downsample($0, maxPixel: 512) }
        for (label, images, formats) in [("photo", photos, [(UTType.heic, 0.95), (.jpeg, 0.95), (.jpeg, 0.9)]),
                                         ("sprite", sprites, [(UTType.png, 1.0), (.heic, 0.95)])] {
            for (type, quality) in formats {
                var files: [URL] = []
                var bytes = 0
                let encode = time("\(label) encode \(type.preferredFilenameExtension!) q\(quality)") {
                    for (index, image) in images.enumerated() {
                        let url = dir.appendingPathComponent("\(label)\(index)-\(quality).\(type.preferredFilenameExtension!)")
                        let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
                        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
                        CGImageDestinationFinalize(destination)
                        files.append(url)
                    }
                }
                bytes = files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
                let decode = time("\(label) decode \(type.preferredFilenameExtension!) q\(quality)") {
                    DispatchQueue.concurrentPerform(iterations: files.count) { index in
                        XCTAssertNotNil(ImagePipeline.decodeFully(files[index]))
                    }
                }
                print("⏱ \(label) \(type.preferredFilenameExtension!) q\(quality): \(bytes / max(files.count, 1) / 1024) KB avg, encode \(Int(encode)) decode \(Int(decode))")
            }
        }
    }
}
