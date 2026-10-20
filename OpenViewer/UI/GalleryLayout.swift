import UIKit

/// Two-section layout: folder cards on top, then images either in a justified grid
/// (Google Photos / Flickr style: equal-height rows, original aspect ratios, full-width rows)
/// or in a square grid. Frames are precomputed with plain arithmetic and looked up with a
/// binary search, so it stays fast with 100k+ items.
final class GalleryLayout: UICollectionViewLayout {
    enum Style: String { case justified, square }

    static let folderSection = 0
    static let imageSection = 1
    static let groupHeaderKind = "OpenViewer.groupHeader"

    /// A run of images shown under one header (e.g. one subfolder in "All Images").
    struct Group: Equatable {
        let start: Int
        let title: String
        let subtitle: String
    }

    var style: Style = .justified { didSet { if style != oldValue { setNeedsRecompute() } } }
    /// Row height (justified) or target cell width (square), in points.
    var targetSize: CGFloat = 150 { didSet { if targetSize != oldValue { setNeedsRecompute() } } }
    /// Aspect ratio (width / height) of each image, in section order.
    var ratios: [CGFloat] = [] { didSet { setNeedsRecompute() } }
    /// Optional grouping of the image section, in order; empty = one continuous grid.
    var groups: [Group] = [] { didSet { if groups != oldValue { setNeedsRecompute() } } }

    let headerHeight: CGFloat = 56
    private(set) var headerFrames: [CGRect] = []

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
        imageFrames = []
        imageFrames.reserveCapacity(imageCount)
        rows = []
        headerFrames = []
        // Rows never span two groups: each group starts under its own header.
        let starts = groups.map(\.start).filter { $0 < imageCount }
        let bounds = starts.isEmpty ? [0..<imageCount]
            : zip(starts, starts.dropFirst() + [imageCount]).map { $0..<$1 }
        if !starts.isEmpty && starts[0] > 0 { y = layoutImages(0..<starts[0], width: width, startY: y) }
        for range in bounds where !range.isEmpty || starts.isEmpty {
            if !starts.isEmpty {
                headerFrames.append(CGRect(x: 0, y: y, width: width, height: headerHeight))
                y += headerHeight
            }
            y = layoutImages(range, width: width, startY: y)
        }
        contentHeight = y
    }

    /// Folder cards: a 4:3 mosaic plus two text lines, as many columns as fit ~240 pt each.
    private func computeFolders(count: Int, width: CGFloat) -> CGFloat {
        folderFrames = []
        guard count > 0 else { return 0 }
        let inset: CGFloat = 20, columnGap: CGFloat = 18, rowGap: CGFloat = 22
        let columns = max(2, Int((width - inset * 2 + columnGap) / (240 + columnGap)))
        let itemWidth = ((width - inset * 2 - columnGap * CGFloat(columns - 1)) / CGFloat(columns)).rounded(.down)
        let textHeight: CGFloat = 52
        let height = (itemWidth * 3 / 4).rounded() + textHeight
        folderFrames.reserveCapacity(count)
        for index in 0..<count {
            let column = index % columns, row = index / columns
            folderFrames.append(CGRect(x: inset + CGFloat(column) * (itemWidth + columnGap),
                                       y: 16 + CGFloat(row) * (height + rowGap),
                                       width: itemWidth, height: height))
        }
        return (folderFrames.last?.maxY ?? 0) + 24
    }

    private func layoutImages(_ range: Range<Int>, width: CGFloat, startY: CGFloat) -> CGFloat {
        switch style {
        case .justified: return computeJustified(range, width: width, startY: startY)
        case .square: return computeSquare(range, width: width, startY: startY)
        }
    }

    private func computeJustified(_ range: Range<Int>, width: CGFloat, startY: CGFloat) -> CGFloat {
        let count = range.upperBound
        var y = startY
        var rowStart = range.lowerBound
        var ratioSum: CGFloat = 0

        func ratio(_ index: Int) -> CGFloat {
            index < ratios.count ? ratios[index] : ImageMetricsStore.placeholderRatio
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

        for index in range {
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

    private func computeSquare(_ range: Range<Int>, width: CGFloat, startY: CGFloat) -> CGFloat {
        let count = range.upperBound
        let columns = max(2, Int(((width + spacing) / (targetSize + spacing)).rounded()))
        let side = (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        var y = startY
        var index = range.lowerBound
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
        if let first = firstHeader(atOrAfter: rect.minY - headerHeight) {
            var index = first
            while index < headerFrames.count, headerFrames[index].minY <= rect.maxY {
                if headerFrames[index].intersects(rect),
                   let header = layoutAttributesForSupplementaryView(ofKind: Self.groupHeaderKind,
                                                                    at: IndexPath(item: index, section: Self.imageSection)) {
                    result.append(header)
                }
                index += 1
            }
        }
        return result
    }

    override func layoutAttributesForSupplementaryView(ofKind elementKind: String,
                                                       at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard elementKind == Self.groupHeaderKind, headerFrames.indices.contains(indexPath.item) else { return nil }
        let attributes = UICollectionViewLayoutAttributes(forSupplementaryViewOfKind: elementKind, with: indexPath)
        attributes.frame = headerFrames[indexPath.item]
        return attributes
    }

    private func firstHeader(atOrAfter y: CGFloat) -> Int? {
        guard !headerFrames.isEmpty else { return nil }
        var low = 0, high = headerFrames.count
        while low < high {
            let mid = (low + high) / 2
            if headerFrames[mid].minY < y { low = mid + 1 } else { high = mid }
        }
        return low
    }

    /// The group shown at a given content offset (for the fast scroller's label).
    func groupIndex(atY y: CGFloat) -> Int? {
        guard !headerFrames.isEmpty else { return nil }
        var low = 0, high = headerFrames.count
        while low < high {
            let mid = (low + high) / 2
            if headerFrames[mid].minY <= y { low = mid + 1 } else { high = mid }
        }
        return max(low - 1, 0)
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
