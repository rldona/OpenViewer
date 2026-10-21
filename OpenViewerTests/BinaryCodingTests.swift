import XCTest
@testable import OpenViewer

final class BinaryCodingTests: XCTestCase {
    func testPrimitivesRoundTrip() throws {
        var writer = BinaryWriter(magic: "TEST", version: 7)
        writer.write(UInt64.max)
        writer.write(Int64(-42))
        writer.write(3.25)
        writer.write(Float(0.5))
        writer.writeCount(60) // counts can never exceed the file size
        writer.write(String(repeating: "x", count: 300)) // two-byte length
        writer.write("Café ✨ / Hollow Knight")
        writer.write("")
        var reader = try XCTUnwrap(BinaryReader(data: writer.data, magic: "TEST", version: 7))
        XCTAssertEqual(reader.read(UInt64.self), .max)
        XCTAssertEqual(reader.read(Int64.self), -42)
        XCTAssertEqual(reader.readDouble(), 3.25)
        XCTAssertEqual(reader.readFloat(), 0.5)
        XCTAssertEqual(reader.readCount(), 60)
        XCTAssertEqual(reader.readString().count, 300)
        XCTAssertEqual(reader.readString(), "Café ✨ / Hollow Knight")
        XCTAssertEqual(reader.readString(), "")
        XCTAssertTrue(reader.isValid)
        XCTAssertTrue(reader.isAtEnd)
    }

    func testRejectsForeignAndTruncatedData() {
        var writer = BinaryWriter(magic: "TEST", version: 1)
        writer.write("hello")
        XCTAssertNil(BinaryReader(data: writer.data, magic: "TEST", version: 2))
        XCTAssertNil(BinaryReader(data: writer.data, magic: "NOPE", version: 1))
        var reader = BinaryReader(data: writer.data.prefix(writer.data.count - 2), magic: "TEST", version: 1)!
        _ = reader.readString()
        XCTAssertFalse(reader.isValid)
        _ = reader.read(UInt64.self)
        XCTAssertFalse(reader.isValid)
    }

    func testScanSnapshotRoundTrip() throws {
        var snapshot = ScanSnapshot()
        snapshot.directories[""] = .init(modified: 10, subdirectories: ["a"], files: [.init(name: "x.png", size: 5_000_000_000, modified: 1.5)])
        snapshot.directories["a"] = .init(modified: 11, subdirectories: [], files: [])
        let decoded = try XCTUnwrap(ScanCache.decode(ScanCache.encode(snapshot)))
        XCTAssertEqual(decoded.directories.count, 2)
        XCTAssertEqual(decoded.directories[""]?.subdirectories, ["a"])
        XCTAssertEqual(decoded.directories[""]?.files.first?.size, 5_000_000_000)
        XCTAssertEqual(decoded.directories[""]?.files.first?.modified, 1.5)
        XCTAssertNil(ScanCache.decode(Data("garbage".utf8)))
    }

    func testAnalysisRecordsRoundTripWithMissingFields() throws {
        var full = ImageAnalysisRecord(modified: Date(timeIntervalSince1970: 100), size: 12)
        full.palette = [0xFF0000, 0x00FF00]
        full.weights = [0.75, 0.25]
        full.hash = .max
        full.vhash = 3
        full.families = 9
        full.text = "salida"
        var textOnly = ImageAnalysisRecord(modified: Date(timeIntervalSince1970: 200), size: 34)
        textOnly.text = ""
        let records = ["~/a.png": full, "/b.png": textOnly]
        let decoded = try XCTUnwrap(ImageAnalysisStore.decode(ImageAnalysisStore.encode(records)))
        XCTAssertEqual(decoded, records)
    }

    func testAnalysisStoreMigratesPropertyList() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-\(UUID().uuidString).plist")
        defer { try? FileManager.default.removeItem(at: file) }
        var record = ImageAnalysisRecord(modified: Date(timeIntervalSince1970: 1), size: 10)
        record.hash = 77
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(["/legacy/x.png": record]).write(to: file)
        let store = ImageAnalysisStore(fileURL: file)
        let item = ImageItem(url: URL(fileURLWithPath: "/legacy/x.png"), size: 10, modified: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(store.record(for: item)?.hash, 77)
    }
}

final class FolderInfoCacheTests: XCTestCase {
    func testStoredSummaryShowsInstantlyNextSession() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fic-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("album"), withIntermediateDirectories: true)
        try Data([0x89, 0x50]).write(to: root.appendingPathComponent("album/a.png"))
        let store = root.appendingPathComponent("info.bin")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("album")
        let modified = try XCTUnwrap(folder.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)

        let first = FolderInfoCache(fileURL: store)
        let computed = expectation(description: "computed")
        first.info(for: folder, modified: modified) { info in
            XCTAssertEqual(info.imageCount, 1)
            computed.fulfill()
        }
        wait(for: [computed], timeout: 5)
        // Saved after a short debounce.
        let saved = expectation(description: "saved")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { saved.fulfill() }
        wait(for: [saved], timeout: 5)

        let second = FolderInfoCache(fileURL: store)
        var instant: FolderInfoCache.Info?
        second.info(for: folder, modified: modified) { instant = $0 }
        XCTAssertEqual(instant?.imageCount, 1, "a stored summary must be delivered synchronously")
        XCTAssertEqual(instant?.covers.first?.name, "a.png")
    }
}
