import ImageIO
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import OpenViewer

final class OpenViewerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("a/b"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("empty"), withIntermediateDirectories: true)
        try writePNG(root.appendingPathComponent("img10.png"), width: 40, height: 20)
        try writePNG(root.appendingPathComponent("img2.png"), width: 40, height: 20)
        try writePNG(root.appendingPathComponent("a/one.jpg"), width: 10, height: 10, type: .jpeg)
        try writePNG(root.appendingPathComponent("a/b/big.png"), width: 3000, height: 1500)
        try Data("hello".utf8).write(to: root.appendingPathComponent("notes.txt"))
        try Data().write(to: root.appendingPathComponent(".hidden.png"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testImageTypes() {
        for name in ["a.JPG", "b.heic", "c.webp", "d.png", "e.dng", "f.tiff", "g.gif"] {
            XCTAssertTrue(ImageTypes.isImage(URL(fileURLWithPath: "/x/\(name)")), name)
        }
        for name in ["a.txt", "b.pdf", "c.mov", "noext"] {
            XCTAssertFalse(ImageTypes.isImage(URL(fileURLWithPath: "/x/\(name)")), name)
        }
    }

    func testShallowListingSkipsHiddenAndNonImages() {
        let listing = FolderScanner.list(root)
        XCTAssertEqual(Set(listing.folders.map(\.name)), ["a", "empty"])
        XCTAssertEqual(Set(listing.images.map(\.name)), ["img10.png", "img2.png"])
    }

    func testNaturalSort() {
        let images = FolderScanner.list(root).images
        XCTAssertEqual(images.sorted(by: SortOrder(key: .name, ascending: true)).map(\.name), ["img2.png", "img10.png"])
        XCTAssertEqual(images.sorted(by: SortOrder(key: .name, ascending: false)).map(\.name), ["img10.png", "img2.png"])
    }

    func testRecursiveScanFindsEverything() {
        var found: [ImageItem] = []
        FolderScanner.scanRecursively(root, isCancelled: { false }) { found += $0 }
        XCTAssertEqual(Set(found.map(\.name)), ["img10.png", "img2.png", "one.jpg", "big.png"])
    }

    func testRecursiveScanCancellation() {
        var found: [ImageItem] = []
        FolderScanner.scanRecursively(root, isCancelled: { true }) { found += $0 }
        XCTAssertTrue(found.isEmpty)
    }

    func testDownsampleRespectsMaxPixel() throws {
        let image = try XCTUnwrap(ImagePipeline.downsample(root.appendingPathComponent("a/b/big.png"), maxPixel: 256))
        XCTAssertEqual(max(image.width, image.height), 256)
        XCTAssertEqual(image.width, 256)
        XCTAssertEqual(image.height, 128)
        XCTAssertEqual(ImagePipeline.pixelSize(of: root.appendingPathComponent("a/b/big.png")), CGSize(width: 3000, height: 1500))
    }

    func testPipelineLoadsAndCaches() throws {
        let pipeline = ImagePipeline(name: "test-\(UUID().uuidString)", diskCache: true, memoryLimit: 10 << 20, concurrency: 2)
        let request = ImagePipeline.Request(url: root.appendingPathComponent("a/b/big.png"), maxPixel: 256)
        let loaded = expectation(description: "loaded")
        pipeline.load(request) { image in
            XCTAssertNotNil(image)
            loaded.fulfill()
        }
        wait(for: [loaded], timeout: 5)
        XCTAssertNotNil(pipeline.cachedImage(for: request))
        pipeline.clearDisk()
    }

    func testPipelineCancellationNeverCallsBack() {
        let pipeline = ImagePipeline(name: "test-\(UUID().uuidString)", diskCache: false, memoryLimit: 10 << 20, concurrency: 2)
        pipeline.queueSuspendedForTesting = true
        let request = ImagePipeline.Request(url: root.appendingPathComponent("a/b/big.png"), maxPixel: 128)
        let token = pipeline.load(request) { _ in XCTFail("cancelled request must not complete") }
        pipeline.cancel(token)
        pipeline.queueSuspendedForTesting = false
        let settle = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { settle.fulfill() }
        wait(for: [settle], timeout: 2)
    }

    func testMetricsReadFromHeader() {
        let metrics = ImageMetricsStore.read(root.appendingPathComponent("a/b/big.png"))
        XCTAssertEqual(metrics.maxSide, 3000)
        XCTAssertEqual(metrics.ratio, 2, accuracy: 0.001)
        XCTAssertEqual(ImageMetricsStore.read(root.appendingPathComponent("notes.txt")).maxSide, 0)
    }

    func testTransparencyBackgroundCycles() {
        var background = TransparencyBackground.checkerboard
        for _ in TransparencyBackground.allCases { background = background.next }
        XCTAssertEqual(background, .checkerboard)
    }

    func testThumbnailBuckets() {
        XCTAssertEqual(ImagePipeline.thumbnailBucket(forPixels: 100), 256)
        XCTAssertEqual(ImagePipeline.thumbnailBucket(forPixels: 300), 512)
        XCTAssertEqual(ImagePipeline.thumbnailBucket(forPixels: 900), 1024)
        XCTAssertEqual(ImagePipeline.thumbnailBucket(forPixels: 9000), 2048)
    }

    private func writePNG(_ url: URL, width: Int, height: Int, type: UTType = .png) throws {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(UIColor.systemTeal.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }
}
