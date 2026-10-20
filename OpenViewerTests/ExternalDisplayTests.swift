import XCTest
@testable import OpenViewer

final class ExternalDisplayTests: XCTestCase {
    func testFollowsViewerAndClampsZoom() {
        let display = ExternalDisplay.shared
        let item = ImageItem(url: URL(fileURLWithPath: "/tmp/x.png"), size: 1, modified: .distantPast)
        var notifications = 0
        let observer = NotificationCenter.default.addObserver(forName: ExternalDisplay.didChange, object: nil, queue: nil) { _ in
            notifications += 1
        }
        defer { NotificationCenter.default.removeObserver(observer); display.show(nil) }

        display.show(item)
        XCTAssertEqual(display.item?.url, item.url)
        display.show(item)
        XCTAssertEqual(notifications, 1, "showing the same image again is a no-op")

        display.setVisibleRect(CGRect(x: -0.2, y: 0.5, width: 0.6, height: 0.8))
        let rect = display.visibleRect
        XCTAssertEqual(rect.minX, 0, accuracy: 0.0001, "clamped to the image")
        XCTAssertEqual(rect.minY, 0.5, accuracy: 0.0001)
        XCTAssertEqual(rect.width, 0.4, accuracy: 0.0001)
        XCTAssertEqual(rect.height, 0.5, accuracy: 0.0001)

        display.show(nil)
        XCTAssertNil(display.item)
        XCTAssertEqual(display.visibleRect, CGRect(x: 0, y: 0, width: 1, height: 1), "a new image starts unzoomed")
    }
}
