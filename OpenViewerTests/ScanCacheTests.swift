import XCTest
@testable import OpenViewer

final class ScanCacheTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("scan-\(UUID().uuidString)", isDirectory: true)
        for folder in ["a", "a/deep", "b"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        for file in ["top2.png", "top10.png", "a/one.jpg", "a/deep/two.png", "b/three.gif", "notes.txt"] {
            try Data([0]).write(to: root.appendingPathComponent(file))
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        ScanCache.remove(root: root)
    }

    private func scan(_ previous: ScanSnapshot?) throws -> IncrementalScanner.Result {
        try XCTUnwrap(IncrementalScanner.scan(root: root, previous: previous, isCancelled: { false }))
    }

    func testFirstScanFindsImagesInTreeOrder() throws {
        let result = try scan(nil)
        XCTAssertEqual(result.images.map(\.name), ["top2.png", "top10.png", "one.jpg", "two.png", "three.gif"])
        XCTAssertEqual(result.changedDirectories, 4)
    }

    func testUnchangedTreeIsNotListedAgain() throws {
        let first = try scan(nil)
        let second = try scan(first.snapshot)
        XCTAssertEqual(second.changedDirectories, 0)
        XCTAssertEqual(second.images.map(\.url), first.images.map(\.url))
    }

    func testOnlyChangedFoldersAreListedAgain() throws {
        let first = try scan(nil)
        try Data([0]).write(to: root.appendingPathComponent("a/deep/new.png"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("b"))
        let second = try scan(first.snapshot)
        XCTAssertEqual(second.changedDirectories, 2, "the root (b removed) and a/deep (file added)")
        XCTAssertEqual(second.images.map(\.name), ["top2.png", "top10.png", "one.jpg", "new.png", "two.png"])
    }

    func testSnapshotRoundTripAndInstantImages() throws {
        let first = try scan(nil)
        ScanCache.save(first.snapshot, root: root)
        let loaded = try XCTUnwrap(ScanCache.load(root: root))
        XCTAssertEqual(loaded.images(root: root).map(\.url), first.images.map(\.url))
    }

    func testCancellation() {
        XCTAssertNil(IncrementalScanner.scan(root: root, previous: nil, isCancelled: { true }))
    }
}
