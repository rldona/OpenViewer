import XCTest
@testable import OpenViewer

final class ImageAnalysisTests: XCTestCase {
    /// Left `split` of the width in `a`, the rest in `b`, optionally with a gradient for structure.
    private func image(width: Int = 100, height: Int = 80, split: CGFloat, _ a: UIColor, _ b: UIColor, stripes: Bool = false) -> CGImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            return format
        }())
        return renderer.image { context in
            a.setFill()
            context.fill(CGRect(x: 0, y: 0, width: CGFloat(width) * split, height: CGFloat(height)))
            b.setFill()
            context.fill(CGRect(x: CGFloat(width) * split, y: 0, width: CGFloat(width) * (1 - split), height: CGFloat(height)))
            if stripes {
                UIColor.white.setFill()
                // Proportional, so a resized copy is the same picture.
                let w = CGFloat(width)
                for step in 0..<5 {
                    context.fill(CGRect(x: w * CGFloat(step) / 5, y: 0, width: w * 0.06, height: CGFloat(height)))
                }
            }
        }.cgImage!
    }

    func testPaletteFindsMainColoursInOrder() {
        let palette = ColorPalette.extract(from: image(split: 0.7, .red, .blue))
        XCTAssertEqual(palette.count, 2)
        XCTAssertEqual(ColorFamily.of(palette[0].rgb), .red)
        XCTAssertEqual(ColorFamily.of(palette[1].rgb), .blue)
        XCTAssertEqual(palette[0].weight, 0.7, accuracy: 0.05)
    }

    func testColorFamilies() {
        XCTAssertEqual(ColorFamily.of(0xF5B545), .orange)
        XCTAssertEqual(ColorFamily.of(0x2E8B57), .green)
        XCTAssertEqual(ColorFamily.of(0x0A0A0A), .black)
        XCTAssertEqual(ColorFamily.of(0xF4F4F4), .white)
        XCTAssertEqual(ColorFamily.of(0x808080), .gray)
        XCTAssertEqual(ColorFamily.of(0xFF69B4), .pink)
        let mask = ColorFamily.mask(palette: [0xFF0000, 0x0000FF, 0x00FF00], weights: [0.6, 0.35, 0.05])
        XCTAssertNotEqual(mask & ColorFamily.red.bit, 0)
        XCTAssertNotEqual(mask & ColorFamily.blue.bit, 0)
        XCTAssertEqual(mask & ColorFamily.green.bit, 0, "a 5 % accent doesn't count")
    }

    func testHashSurvivesResizeButSeparatesDifferentImages() throws {
        let original = try XCTUnwrap(ImageHash.dHash(image(split: 0.3, .red, .blue, stripes: true)))
        let resized = try XCTUnwrap(ImageHash.dHash(image(width: 400, height: 320, split: 0.3, .red, .blue, stripes: true)))
        let different = try XCTUnwrap(ImageHash.dHash(image(split: 0.8, .green, .black)))
        XCTAssertLessThanOrEqual(ImageHash.distance(original, resized), 4)
        XCTAssertGreaterThan(ImageHash.distance(original, different), 6)
    }

    func testStoreForgetsChangedFiles() {
        let store = ImageAnalysisStore(fileURL: nil)
        let url = URL(fileURLWithPath: "/tmp/a.png")
        let item = ImageItem(url: url, size: 10, modified: Date(timeIntervalSince1970: 100))
        store.update(item) { $0.text = "puerta" }
        XCTAssertTrue(store.has(.text, for: item))
        XCTAssertEqual(store.keys(containingText: "PUERTA").count, 1)
        let edited = ImageItem(url: url, size: 11, modified: Date(timeIntervalSince1970: 200))
        XCTAssertFalse(store.has(.text, for: edited))
    }
}
