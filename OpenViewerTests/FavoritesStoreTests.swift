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

    func testReorderPersists() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("folders-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = FavoriteFoldersStore(fileURL: file)
        for name in ["A", "B", "C"] { store.set(URL(fileURLWithPath: "/tmp/\(name)", isDirectory: true), favorite: true) }
        XCTAssertEqual(store.items.map(\.name), ["C", "B", "A"])
        let ids = store.items.map(\.id)
        store.reorder([ids[2], ids[0]])
        XCTAssertEqual(store.items.map(\.name), ["A", "C", "B"])
        XCTAssertEqual(FavoriteFoldersStore(fileURL: file).items.map(\.name), ["A", "C", "B"])
    }
}

final class PathKeyTests: XCTestCase {
    func testAppContainerPathsAreRelative() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let file = documents.appendingPathComponent("Art/hornet.png")
        let key = PathKey.make(file.path)
        XCTAssertEqual(key, "~/Documents/Art/hornet.png")
        XCTAssertEqual(PathKey.url(key).path, file.path)
    }

    func testOtherPathsStayAbsolute() {
        XCTAssertEqual(PathKey.make("/private/var/mobile/Library/Mobile Documents/x.png"), "/var/mobile/Library/Mobile Documents/x.png")
    }

    func testMigratesKeysFromAnOldContainer() {
        let old = "/private/var/mobile/Containers/Data/Application/1DD8854D-4E0D-433B-BDB6-A0DB772E6C3D/Documents/Fotos/a.jpg"
        XCTAssertEqual(PathKey.migrate(old), "~/Documents/Fotos/a.jpg")
        let simulator = "/Users/me/Library/Developer/CoreSimulator/Devices/X/data/Containers/Data/Application/E7459E73-90DC-4048-BA7E-351762F2BA0E/Documents/Fotos"
        XCTAssertEqual(PathKey.migrate(simulator), "~/Documents/Fotos")
        XCTAssertEqual(PathKey.migrate("~/Documents/b.png"), "~/Documents/b.png")
    }
}
