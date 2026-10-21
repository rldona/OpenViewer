import ImageIO
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import OpenViewer

final class FrameSequenceTests: XCTestCase {
    private func item(_ path: String) -> ImageItem {
        ImageItem(url: URL(fileURLWithPath: path), size: 0, modified: .distantPast)
    }

    func testStem() {
        XCTAssertEqual(FrameSequence.stem(of: "Attack_01.png"), "attack")
        XCTAssertEqual(FrameSequence.stem(of: "walk-12.PNG"), "walk")
        XCTAssertEqual(FrameSequence.stem(of: "idle 3.gif"), "idle")
        XCTAssertEqual(FrameSequence.stem(of: "frame10.png"), "frame")
        XCTAssertNil(FrameSequence.stem(of: "hornet.png"))
    }

    func testFramesStayInFolderAndSortNaturally() {
        let items = [
            item("/a/walk_10.png"), item("/a/walk_2.png"), item("/a/walk_1.png"),
            item("/a/run_1.png"), item("/b/walk_3.png"), item("/a/cover.png"),
        ]
        let frames = FrameSequence.frames(around: items[1], in: items)
        XCTAssertEqual(frames.map(\.name), ["walk_1.png", "walk_2.png", "walk_10.png"])
        XCTAssertTrue(FrameSequence.frames(around: items[3], in: items).isEmpty, "a single frame is not a sequence")
        XCTAssertTrue(FrameSequence.frames(around: items[5], in: items).isEmpty)
    }
}

final class AnimatedImageTests: XCTestCase {
    func testReadsFramesAndTheirOwnTiming() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("anim-\(UUID().uuidString).gif")
        defer { try? FileManager.default.removeItem(at: url) }
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, 3, nil))
        for (index, delay) in [0.05, 0.2, 0.0].enumerated() {
            let context = CGContext(data: nil, width: 20, height: 10, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(index == 1 ? UIColor.red.cgColor : UIColor.blue.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 20, height: 10))
            CGImageDestinationAddImage(destination, context.makeImage()!,
                                       [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        XCTAssertEqual(AnimatedImage.frameCount(of: url), 3)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let delays = AnimatedImage.delays(of: source)
        XCTAssertEqual(delays.count, 3)
        XCTAssertEqual(delays[0], 0.05, accuracy: 0.001)
        XCTAssertEqual(delays[1], 0.2, accuracy: 0.001)
        XCTAssertEqual(delays[2], 0.1, accuracy: 0.001, "a zero delay plays like browsers do")
    }

    func testStillImagesHaveOneFrame() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("still-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        XCTAssertEqual(AnimatedImage.frameCount(of: url), 1)
        XCTAssertEqual(AnimatedImage.frameCount(of: URL(fileURLWithPath: "/nope/missing.jpg")), 1)
    }
}
