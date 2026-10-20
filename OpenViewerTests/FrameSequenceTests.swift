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
