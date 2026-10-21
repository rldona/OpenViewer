import XCTest
@testable import OpenViewer

final class BoardArrangementTests: XCTestCase {
    private func item(_ x: Double, _ y: Double, width: Double = 500, rotation: Double = 0.3) -> BoardItem {
        BoardItem(id: UUID(), path: "/b/\(x)-\(y).png", bookmark: nil, centerX: x, centerY: y, width: width, rotation: rotation)
    }

    func testReadingOrderIsRowsThenLeftToRight() {
        let a = item(900, 110), b = item(100, 90), c = item(500, 700), d = item(100, 720)
        let order = BoardArrangement.readingOrder([a, b, c, d]) { _ in 1 }
        XCTAssertEqual(order.map(\.id), [b.id, a.id, d.id, c.id])
    }

    func testGridGivesEqualCellsAndNoRotation() {
        let items = (0..<5).map { item(Double($0) * 37, Double($0 % 2) * 900) }
        var aspects: [UUID: Double] = [:]
        items.enumerated().forEach { aspects[$1.id] = $0 == 0 ? 2 : 0.5 } // one tall, the rest wide
        let arranged = BoardArrangement.grid.apply(to: items, aspects: aspects)
        XCTAssertEqual(arranged.map(\.id), items.map(\.id), "layer order is kept")
        XCTAssertTrue(arranged.allSatisfy { $0.rotation == 0 })
        for item in arranged {
            let a = aspects[item.id]!
            XCTAssertLessThanOrEqual(max(item.width, item.width * a), BoardArrangement.cell + 0.001, "fits its cell")
            XCTAssertEqual(max(item.width, item.width * a), BoardArrangement.cell, accuracy: 0.001, "fills its cell's long side")
        }
        // 5 items → 3 columns: cell centres sit on a regular grid.
        let xs = Set(arranged.map { ($0.centerX * 10).rounded() / 10 })
        XCTAssertLessThanOrEqual(xs.count, 5)
    }

    func testRowsShareHeightAndWidth() {
        let items = (0..<7).map { item(Double($0) * 300, 0) }
        let aspects = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($1.id, [0.5, 1, 0.75, 1.5][$0 % 4]) })
        let arranged = BoardArrangement.rows.apply(to: items, aspects: aspects)
        let rows = Dictionary(grouping: arranged) { ($0.centerY * 10).rounded() }
        XCTAssertGreaterThan(rows.count, 1)
        for row in rows.values {
            let heights = row.map { $0.width * aspects[$0.id]! }
            XCTAssertEqual(heights.min()!, heights.max()!, accuracy: 0.01, "a row has one height")
        }
        // Rows are centred on the same vertical axis.
        let centres = rows.values.map { row -> Double in
            let minX = row.map { $0.centerX - $0.width / 2 }.min()!, maxX = row.map { $0.centerX + $0.width / 2 }.max()!
            return (minX + maxX) / 2
        }
        XCTAssertEqual(centres.min()!, centres.max()!, accuracy: 0.5)
    }

    func testStaysWhereTheBoardWas() {
        let items = [item(5000, 5000), item(5600, 5100), item(5200, 5800)]
        let arranged = BoardArrangement.grid.apply(to: items, aspects: [:])
        let cx = (arranged.map { $0.centerX - $0.width / 2 }.min()! + arranged.map { $0.centerX + $0.width / 2 }.max()!) / 2
        XCTAssertEqual(cx, 5300, accuracy: 1)
    }
}
