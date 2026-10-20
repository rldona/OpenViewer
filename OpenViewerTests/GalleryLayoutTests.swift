import UIKit
import XCTest
@testable import OpenViewer

final class GalleryLayoutTests: XCTestCase {
    private final class Source: NSObject, UICollectionViewDataSource {
        let folders: Int, images: Int
        init(folders: Int, images: Int) { self.folders = folders; self.images = images }
        func numberOfSections(in collectionView: UICollectionView) -> Int { 2 }
        func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
            section == 0 ? folders : images
        }
        func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
            collectionView.dequeueReusableCell(withReuseIdentifier: "c", for: indexPath)
        }
    }

    private func makeLayout(ratios: [CGFloat], folders: Int = 0, style: GalleryLayout.Style = .justified) -> (GalleryLayout, UICollectionView, Source) {
        let layout = GalleryLayout()
        layout.style = style
        layout.targetSize = 150
        layout.ratios = ratios
        let collectionView = UICollectionView(frame: CGRect(x: 0, y: 0, width: 1000, height: 800), collectionViewLayout: layout)
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "c")
        let source = Source(folders: folders, images: ratios.count)
        collectionView.dataSource = source
        collectionView.layoutIfNeeded()
        return (layout, collectionView, source)
    }

    func testJustifiedRowsFillWidthAndKeepProportions() {
        let ratios: [CGFloat] = [1.5, 0.75, 1.5, 1, 1.5, 4, 1.5, 0.75, 1.5, 1, 1.5]
        let (layout, _, _) = makeLayout(ratios: ratios)
        let frames = layout.imageFrames
        XCTAssertEqual(frames.count, ratios.count)

        let rows = Dictionary(grouping: frames.indices, by: { frames[$0].minY }).sorted { $0.key < $1.key }
        XCTAssertGreaterThan(rows.count, 1)
        for (rowNumber, row) in rows.enumerated() {
            let heights = Set(row.value.map { frames[$0].height })
            XCTAssertEqual(heights.count, 1, "every item in a row has the same height")
            for index in row.value.dropLast() {
                XCTAssertEqual(frames[index].width / frames[index].height, ratios[index], accuracy: 0.05)
            }
            if rowNumber < rows.count - 1 {
                XCTAssertEqual(row.value.map { frames[$0].maxX }.max()!, 1000, accuracy: 0.5, "full rows reach the edge")
            }
        }
    }

    func testPanoramaGetsItsOwnFullWidthRow() {
        let (layout, _, _) = makeLayout(ratios: [10, 1, 1])
        XCTAssertEqual(layout.imageFrames[0].width, 1000, accuracy: 0.5)
        XCTAssertGreaterThan(layout.imageFrames[1].minY, layout.imageFrames[0].maxY)
    }

    func testSquareStyleAndVisibleQuery() {
        let (layout, _, _) = makeLayout(ratios: Array(repeating: 1.5, count: 500), folders: 3, style: .square)
        XCTAssertTrue(layout.imageFrames.allSatisfy { abs($0.width - $0.height) < 0.01 })
        let visible = layout.layoutAttributesForElements(in: CGRect(x: 0, y: 0, width: 1000, height: 800)) ?? []
        XCTAssertTrue(visible.contains { $0.indexPath.section == 0 })
        XCTAssertLessThan(visible.count, 100, "only on-screen items are returned")
    }
}
