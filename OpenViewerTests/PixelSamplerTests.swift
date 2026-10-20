import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import OpenViewer

final class PixelSamplerTests: XCTestCase {
    /// 4×2 PNG: left half opaque amber, right half 50 % blue. Untagged device RGB, like most game rips.
    private func makePNG() throws -> URL {
        let context = CGContext(data: nil, width: 4, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [245 / 255, 181 / 255, 69 / 255, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        context.setFillColor(CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [0, 0, 1, 0.5])!)
        context.fill(CGRect(x: 2, y: 0, width: 2, height: 2))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pixels-\(UUID().uuidString).png")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    func testExactColoursAndCoordinates() throws {
        let url = try makePNG()
        defer { try? FileManager.default.removeItem(at: url) }
        let sampler = PixelSampler(url: url)
        let ready = expectation(description: "decoded")
        sampler.prepare { ready.fulfill() }
        wait(for: [ready], timeout: 5)

        let amber = try XCTUnwrap(sampler.sample(atUnit: CGPoint(x: 0.1, y: 0.9)))
        XCTAssertEqual(amber.hex, "#F5B545")
        XCTAssertEqual(amber.x, 0)
        XCTAssertEqual(amber.y, 1)

        let blue = try XCTUnwrap(sampler.sample(atUnit: CGPoint(x: 0.9, y: 0.1)))
        XCTAssertEqual(blue.x, 3)
        XCTAssertEqual(blue.b, 255, "semi-transparent pixels report their straight colour")
        XCTAssertEqual(Int(blue.a), 128, accuracy: 1)
        XCTAssertNil(sampler.sample(atUnit: CGPoint(x: 1.2, y: 0.5)))
    }
}
