import XCTest
@testable import OpenViewer

final class DuplicateFinderTests: XCTestCase {
    private func print(_ hash: UInt64, _ vhash: UInt64 = 0x0F0F_0F0F_0F0F_0F0F, color: UInt32 = 0xFF0000) -> DuplicateFinder.Signature {
        .init(hash: hash, vhash: vhash, palette: [color], weights: [1])
    }

    func testGroupsNearIdenticalImages() {
        let base: UInt64 = 0xF0F0_1234_ABCD_0F0F
        let other: UInt64 = 0x0123_4567_89AB_CDEF
        let prints: [DuplicateFinder.Signature?] = [
            print(base),                         // 0
            print(base ^ 0b101),                 // 1: 2 bits off → same group
            print(other),                        // 2: unrelated
            print(base ^ (1 << 63)),             // 3: 1 bit off → same group
            print(other ^ 1),                    // 4: 1 bit off from 2 → its own group
            nil,                                 // 5: not analysed
            print(0, 0), print(0, 0),            // 6, 7: flat images never match
            print(base, color: 0x0000FF),        // 8: same shape, different colour
        ]
        XCTAssertEqual(DuplicateFinder.groups(prints), [[0, 1, 3], [2, 4]])
    }

    func testBothFingerprintsMustAgree() {
        let a: UInt64 = 0xFFFF_FFFF_0000_0000
        XCTAssertTrue(DuplicateFinder.groups([print(a), print(a ^ 0xFF)]).isEmpty, "8 bits apart is not a duplicate")
        XCTAssertTrue(DuplicateFinder.groups([print(a, 0x1111), print(a, 0xEEEE_0000)]).isEmpty, "vertical structure differs")
    }

    func testNoChaining() {
        // Each step is 2 bits from the previous one, but the ends are 8 bits apart.
        let a: UInt64 = 0xAAAA_AAAA_AAAA_AAAA
        let chain = (0..<5).map { step in print(a ^ ((1 << UInt64(step * 2)) - 1)) }
        let groups = DuplicateFinder.groups(chain)
        XCTAssertFalse(groups.contains { $0.count == 5 }, "a chain of small changes is not one group")
    }

    func testScalesToLargeLibraries() {
        var generator = SystemRandomNumberGenerator()
        var prints: [DuplicateFinder.Signature?] = (0..<50_000).map { _ in
            print(UInt64.random(in: 1...UInt64.max, using: &generator), UInt64.random(in: 1...UInt64.max, using: &generator))
        }
        prints.append(print(prints[123]!.hash ^ 1, prints[123]!.vhash))
        let start = CFAbsoluteTimeGetCurrent()
        let groups = DuplicateFinder.groups(prints)
        XCTAssertLessThan(CFAbsoluteTimeGetCurrent() - start, 3)
        XCTAssertTrue(groups.contains([123, 50_000]))
    }

    func testSimilarRanksCloseImagesFirst() {
        let target = print(0xAAAA_AAAA_AAAA_AAAA)
        let candidates: [DuplicateFinder.Signature?] = [
            print(0x5555_5555_5555_5555, 0xF0F0_F0F0_F0F0_F0F0, color: 0x0000FF), // nothing alike
            print(0xAAAA_AAAA_AAAA_AAAB, color: 0xF00000),                         // nearly the same
            nil,
            print(0xAAAA_AAAA_AAAA_AAFF),                                          // close
        ]
        XCTAssertEqual(DuplicateFinder.similar(to: target, among: candidates), [1, 3])
    }
}

final class DuplicateEndToEndTests: XCTestCase {
    private func writeJPEG(_ size: CGSize, to url: URL, shift: CGFloat = 0, quality: CGFloat = 0.9) throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor(red: 0.1, green: 0.2, blue: 0.4, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.orange.setFill()
            context.fill(CGRect(x: size.width * (0.1 + shift), y: size.height * 0.5, width: size.width * 0.3, height: size.height * 0.3))
            UIColor.white.setFill()
            UIBezierPath(ovalIn: CGRect(x: size.width * 0.6, y: size.height * 0.1, width: size.width * 0.25, height: size.width * 0.25)).fill()
        }
        try XCTUnwrap(image.jpegData(compressionQuality: quality)).write(to: url)
    }

    func testFindsCopiesAndResizedVersions() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("dups-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let names = ["original.jpg", "small.jpg", "recompressed.jpg", "different.jpg"]
        try writeJPEG(CGSize(width: 1200, height: 800), to: folder.appendingPathComponent(names[0]))
        try writeJPEG(CGSize(width: 300, height: 200), to: folder.appendingPathComponent(names[1]))
        try writeJPEG(CGSize(width: 1200, height: 800), to: folder.appendingPathComponent(names[2]), quality: 0.4)
        try writeJPEG(CGSize(width: 1200, height: 800), to: folder.appendingPathComponent(names[3]), shift: 0.5)

        let prints = names.map { name -> DuplicateFinder.Signature? in
            ImageAnalyzer.visual(folder.appendingPathComponent(name)).map {
                .init(hash: $0.hash, vhash: $0.vhash, palette: $0.palette, weights: $0.weights)
            }
        }
        XCTAssertEqual(DuplicateFinder.groups(prints), [[0, 1, 2]])
    }
}
