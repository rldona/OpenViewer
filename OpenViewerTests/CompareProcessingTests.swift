import XCTest
@testable import OpenViewer

final class CompareProcessingTests: XCTestCase {
    private func solid(_ color: UIColor, size: CGSize = CGSize(width: 20, height: 10), patch: UIColor? = nil) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            if let patch {
                patch.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 5, height: 5))
            }
        }
    }

    private func brightness(_ image: UIImage?, at point: CGPoint) -> Int {
        guard let cg = image?.cgImage,
              let pixels = ColorPalette.rgbaPixels(cg, width: cg.width, height: cg.height, quality: .none) else { return -1 }
        let i = (Int(point.y) * cg.width + Int(point.x)) * 4
        return Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + 2])
    }

    func testDifferenceIsBlackWhereImagesMatch() {
        let a = solid(.red)
        let b = solid(.red, patch: .white)
        let result = CompareViewController.process(.difference, a, b)
        XCTAssertNil(result.top)
        XCTAssertEqual(brightness(result.base, at: CGPoint(x: 15, y: 8)), 0, "identical area")
        XCTAssertGreaterThan(brightness(result.base, at: CGPoint(x: 2, y: 2)), 300, "changed area is bright")
    }

    func testOnionSkinTintsEachImage() {
        let result = CompareViewController.process(.onion, solid(.white), solid(.white))
        XCTAssertNotNil(result.base)
        XCTAssertNotNil(result.top)
        guard let base = result.base?.cgImage, let top = result.top?.cgImage,
              let a = ColorPalette.rgbaPixels(base, width: 1, height: 1), let b = ColorPalette.rgbaPixels(top, width: 1, height: 1) else {
            return XCTFail("no pixels")
        }
        XCTAssertGreaterThan(a[0], a[2], "A is reddish")
        XCTAssertGreaterThan(b[2], b[0], "B is cyan-ish")
    }
}
