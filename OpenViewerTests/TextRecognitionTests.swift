import XCTest
@testable import OpenViewer

final class TextRecognitionTests: XCTestCase {
    /// A map-like image with a small legend, as in decoded game maps.
    func testReadsLegendText() throws {
        let size = CGSize(width: 1200, height: 800)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(red: 0.1, green: 0.15, blue: 0.3, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 28, weight: .semibold), .foregroundColor: UIColor.white]
            ("Puerta secreta" as NSString).draw(at: CGPoint(x: 40, y: 40), withAttributes: attributes)
            ("Enemigo" as NSString).draw(at: CGPoint(x: 40, y: 90), withAttributes: attributes)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("legend-\(UUID().uuidString).png")
        try XCTUnwrap(image.pngData()).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let text = try XCTUnwrap(ImageAnalyzer.text(url))
        XCTAssertTrue(text.contains("puerta"), "got: \(text)")
        XCTAssertTrue(text.contains("enemigo"), "got: \(text)")
    }
}
