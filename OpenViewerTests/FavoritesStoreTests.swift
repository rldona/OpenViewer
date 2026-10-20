import XCTest
@testable import OpenViewer

final class FavoritesStoreTests: XCTestCase {
    private var file: URL!

    override func setUp() {
        file = FileManager.default.temporaryDirectory.appendingPathComponent("fav-\(UUID().uuidString).plist")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: file)
    }

    func testToggleAndPersistence() {
        let url = URL(fileURLWithPath: "/var/mobile/Pics/hornet.png")
        let store = FavoritesStore(fileURL: file)
        XCTAssertFalse(store.contains(url))
        XCTAssertTrue(store.toggle(url))
        XCTAssertTrue(store.contains(url))
        XCTAssertEqual(FavoritesStore(fileURL: file).count, 1, "favorites survive a relaunch")
        XCTAssertFalse(store.toggle(url))
        XCTAssertEqual(FavoritesStore(fileURL: file).count, 0)
    }

    func testPrivateVarAliasIsTheSameFile() {
        let store = FavoritesStore(fileURL: file)
        store.set(URL(fileURLWithPath: "/private/var/mobile/Pics/knight.png"), favorite: true)
        XCTAssertTrue(store.contains(URL(fileURLWithPath: "/var/mobile/Pics/knight.png")))
    }

    func testMostRecentFirstAndNotification() {
        let store = FavoritesStore(fileURL: file)
        let first = URL(fileURLWithPath: "/a/1.png"), second = URL(fileURLWithPath: "/a/2.png")
        let posted = expectation(forNotification: FavoritesStore.didChange, object: nil)
        posted.expectedFulfillmentCount = 2
        store.set(first, favorite: true)
        Thread.sleep(forTimeInterval: 0.01)
        store.set(second, favorite: true)
        wait(for: [posted], timeout: 1)
        XCTAssertEqual(store.urls.map(\.lastPathComponent), ["2.png", "1.png"])
    }
}

final class FavoriteFoldersStoreTests: XCTestCase {
    func testToggleResolveAndPersist() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("folders-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Hornet-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = FavoriteFoldersStore(fileURL: file)
        XCTAssertTrue(store.toggle(folder))
        XCTAssertTrue(store.contains(folder))
        let reloaded = FavoriteFoldersStore(fileURL: file)
        XCTAssertEqual(reloaded.items.map(\.name), [folder.lastPathComponent])
        XCTAssertEqual(FavoritesStore.key(reloaded.resolve(reloaded.items[0])), FavoritesStore.key(folder))
        reloaded.remove(reloaded.items[0].id)
        XCTAssertTrue(FavoriteFoldersStore(fileURL: file).items.isEmpty)
    }
}
