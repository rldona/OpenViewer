import UIKit

/// Two-section layout: folder cards on top, then images either in a justified grid
/// (Google Photos / Flickr style: equal-height rows, original aspect ratios, full-width rows)
/// or in a square grid. Frames are precomputed with plain arithmetic and looked up with a
/// binary search, so it stays fast with 100k+ items.
final class GalleryLayout: UICollectionViewLayout {
    enum Style: String { case justified, square }

    static let folderSection = 0
    static let imageSection = 1

    var style: Style = .justified { didSet { if style != oldValue { setNeedsRecompute() } } }
    /// Row height (justified) or target cell width (square), in points.
    var targetSize: CGFloat = 150 { didSet { if targetSize != oldValue { setNeedsRecompute() } } }
    /// Aspect ratio (width / height) of each image, in section order.
    var ratios: [CGFloat] = [] { didSet { setNeedsRecompute() } }

    let spacing: CGFloat = 3

    private(set) var imageFrames: [CGRect] = []
    private var folderFrames: [CGRect] = []
    /// Rows of the image section: item range plus vertical extent, sorted by y.
    private var rows: [(range: Range<Int>, minY: CGFloat, maxY: CGFloat)] = []
    private var contentHeight: CGFloat = 0
    private var computedWidth: CGFloat = -1
    private var needsRecompute = true

    func setNeedsRecompute() {
        needsRecompute = true
        invalidateLayout()
    }

    func imageFrame(at index: Int) -> CGRect? {
        imageFrames.indices.contains(index) ? imageFrames[index] : nil
    }

    // MARK: Computing

    override func prepare() {
        super.prepare()
        guard let collectionView else { return }
        let width = collectionView.bounds.width - collectionView.adjustedContentInset.left - collectionView.adjustedContentInset.right
        guard width > 0, needsRecompute || width != computedWidth else { return }
        needsRecompute = false
        computedWidth = width

        let folderCount = collectionView.numberOfSections > Self.folderSection
            ? collectionView.numberOfItems(inSection: Self.folderSection) : 0
        let imageCount = collectionView.numberOfSections > Self.imageSection
            ? collectionView.numberOfItems(inSection: Self.imageSection) : 0

        var y = computeFolders(count: folderCount, width: width)
        switch style {
        case .justified: y = computeJustified(count: imageCount, width: width, startY: y)
        case .square: y = computeSquare(count: imageCount, width: width, startY: y)
        }
        contentHeight = y
    }

    private func computeFolders(count: Int, width: CGFloat) -> CGFloat {
        folderFrames = []
        guard count > 0 else { return 0 }
        let inset: CGFloat = 16, gap: CGFloat = 10, height: CGFloat = 72
        let columns = max(1, Int((width - inset * 2) / 300))
        let itemWidth = (width - inset * 2 - gap * CGFloat(columns - 1)) / CGFloat(columns)
        folderFrames.reserveCapacity(count)
        for index in 0..<count {
            let column = index % columns, row = index / columns
            folderFrames.append(CGRect(x: inset + CGFloat(column) * (itemWidth + gap),
                                       y: 12 + CGFloat(row) * (height + gap),
                                       width: itemWidth, height: height))
        }
        return (folderFrames.last?.maxY ?? 0) + 16
    }

    private func computeJustified(count: Int, width: CGFloat, startY: CGFloat) -> CGFloat {
        imageFrames = []
        imageFrames.reserveCapacity(count)
        rows = []
        var y = startY
        var rowStart = 0
        var ratioSum: CGFloat = 0

        func ratio(_ index: Int) -> CGFloat {
            index < ratios.count ? ratios[index] : AspectRatioStore.placeholder
        }

        func placeRow(_ range: Range<Int>, height: CGFloat, fill: Bool) {
            var x: CGFloat = 0
            for index in range {
                var itemWidth = (ratio(index) * height).rounded()
                // The last item absorbs rounding so full rows end exactly at the edge.
                if fill && index == range.upperBound - 1 { itemWidth = width - x }
                imageFrames.append(CGRect(x: x, y: y, width: max(itemWidth, 1), height: height))
                x += itemWidth + spacing
            }
            rows.append((range, y, y + height))
            y += height + spacing
        }

        for index in 0..<count {
            ratioSum += ratio(index)
            let itemsInRow = CGFloat(index - rowStart + 1)
            let gaps = spacing * (itemsInRow - 1)
            if ratioSum * targetSize + gaps >= width {
                placeRow(rowStart..<(index + 1), height: ((width - gaps) / ratioSum).rounded(), fill: true)
                rowStart = index + 1
                ratioSum = 0
            }
        }
        if rowStart < count {
            // Last, incomplete row keeps the target height instead of being blown up.
            placeRow(rowStart..<count, height: targetSize, fill: false)
        }
        return y
    }

    private func computeSquare(count: Int, width: CGFloat, startY: CGFloat) -> CGFloat {
        imageFrames = []
        imageFrames.reserveCapacity(count)
        rows = []
        let columns = max(2, Int(((width + spacing) / (targetSize + spacing)).rounded()))
        let side = (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        var y = startY
        var index = 0
        while index < count {
            let end = min(index + columns, count)
            for item in index..<end {
                imageFrames.append(CGRect(x: CGFloat(item - index) * (side + spacing), y: y, width: side, height: side))
            }
            rows.append((index..<end, y, y + side))
            y += side + spacing
            index = end
        }
        return y
    }

    // MARK: UICollectionViewLayout

    override var collectionViewContentSize: CGSize {
        CGSize(width: computedWidth > 0 ? computedWidth : 0, height: contentHeight)
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        guard let collectionView else { return false }
        return newBounds.width != collectionView.bounds.width
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        var result: [UICollectionViewLayoutAttributes] = []
        for (index, frame) in folderFrames.enumerated() where frame.intersects(rect) {
            result.append(attributes(IndexPath(item: index, section: Self.folderSection), frame))
        }
        // Binary search for the first row that reaches into `rect`.
        var low = 0, high = rows.count
        while low < high {
            let mid = (low + high) / 2
            if rows[mid].maxY < rect.minY { low = mid + 1 } else { high = mid }
        }
        var rowIndex = low
        while rowIndex < rows.count, rows[rowIndex].minY <= rect.maxY {
            for index in rows[rowIndex].range {
                result.append(attributes(IndexPath(item: index, section: Self.imageSection), imageFrames[index]))
            }
            rowIndex += 1
        }
        return result
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        let frames = indexPath.section == Self.folderSection ? folderFrames : imageFrames
        guard frames.indices.contains(indexPath.item) else { return nil }
        return attributes(indexPath, frames[indexPath.item])
    }

    // Cells that enter or leave during a resize keep full opacity: the default cross-fade lets
    // the background show through and makes the whole grid flicker.
    override func initialLayoutAttributesForAppearingItem(at itemIndexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        layoutAttributesForItem(at: itemIndexPath)
    }

    override func finalLayoutAttributesForDisappearingItem(at itemIndexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        layoutAttributesForItem(at: itemIndexPath)
    }

    private func attributes(_ indexPath: IndexPath, _ frame: CGRect) -> UICollectionViewLayoutAttributes {
        let attributes = UICollectionViewLayoutAttributes(forCellWith: indexPath)
        attributes.frame = frame
        return attributes
    }
}
