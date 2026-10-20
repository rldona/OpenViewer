import XCTest
@testable import OpenViewer

final class TagStoreTests: XCTestCase {
    func testTagUntagAndPersist() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("tags-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: file) }
        let a = URL(fileURLWithPath: "/tmp/a.png"), b = URL(fileURLWithPath: "/tmp/b.png")
        let store = TagStore(fileURL: file)
        store.set(.blue, on: [a, b], true)
        store.set(.red, on: [a], true)
        XCTAssertEqual(store.tags(for: a), [.red, .blue], "kept in a stable colour order")
        XCTAssertEqual(store.counts.map(\.tag), [.red, .blue])
        XCTAssertEqual(store.counts.map(\.count), [1, 2])

        let reloaded = TagStore(fileURL: file)
        XCTAssertEqual(reloaded.keys(for: .blue).count, 2)
        reloaded.set(.blue, on: [a], false)
        XCTAssertEqual(reloaded.tags(for: a), [.red])
        XCTAssertEqual(reloaded.urls(for: .blue).map(\.lastPathComponent), ["b.png"])
    }

    func testSmartAlbumsPersistInOrder() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("albums-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = SmartAlbumStore(fileURL: file)
        func album(_ name: String) -> SmartAlbum {
            SmartAlbum(id: UUID(), name: name, path: "/tmp", bookmark: nil, includeSubfolders: true, query: "boss",
                       minimumSide: 256, favoritesOnly: false, color: ColorFamily.red.rawValue, tag: TagColor.green.rawValue)
        }
        store.add(album("A"))
        store.add(album("B"))
        store.reorder([store.items[1].id, store.items[0].id])
        let reloaded = SmartAlbumStore(fileURL: file)
        XCTAssertEqual(reloaded.items.map(\.name), ["B", "A"])
        XCTAssertEqual(reloaded.items[0].summary, "All subfolders · “boss” · ≥ 256 px · Red · Green tag")
    }
}
