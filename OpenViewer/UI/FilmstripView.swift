import UIKit

/// Horizontal strip of thumbnails under the viewer. Cells keep each image's proportions at a fixed
/// height and only visible ones load (from the shared thumbnail cache), so it scales to any list.
final class FilmstripView: UIView, UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    var onSelect: ((Int) -> Void)?

    private let items: [ImageItem]
    private let collectionView: UICollectionView
    private let height: CGFloat = 52
    private let selectedHeight: CGFloat = 62
    private(set) var selectedIndex = 0
    private var isUserScrolling = false

    init(items: [ImageItem]) {
        self.items = items
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 4
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        super.init(frame: .zero)
        collectionView.backgroundColor = .clear
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.decelerationRate = .fast
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(FilmstripCell.self, forCellWithReuseIdentifier: FilmstripCell.reuseID)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: bottomAnchor),
            collectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: trailingAnchor),
            heightAnchor.constraint(equalToConstant: selectedHeight + 8),
        ])
        accessibilityLabel = "Filmstrip"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Let the first and last thumbnails reach the centre.
        let side = bounds.width / 2
        if collectionView.contentInset.left != side {
            collectionView.contentInset = UIEdgeInsets(top: 0, left: side, bottom: 0, right: side)
            scrollToSelected(animated: false)
        }
    }

    func select(_ index: Int, animated: Bool) {
        guard items.indices.contains(index) else { return }
        let previous = selectedIndex
        selectedIndex = index
        UIView.performWithoutAnimation {
            collectionView.performBatchUpdates {
                collectionView.collectionViewLayout.invalidateLayout()
            }
            for path in [previous, index].map({ IndexPath(item: $0, section: 0) }) {
                (collectionView.cellForItem(at: path) as? FilmstripCell)?.isCurrent = path.item == index
            }
        }
        if !isUserScrolling { scrollToSelected(animated: animated) }
    }

    private func scrollToSelected(animated: Bool) {
        guard items.indices.contains(selectedIndex), collectionView.bounds.width > 0 else { return }
        collectionView.scrollToItem(at: IndexPath(item: selectedIndex, section: 0), at: .centeredHorizontally, animated: animated)
    }

    private func ratio(at index: Int) -> CGFloat {
        ImageMetricsStore.shared.metrics(for: items[index].url)?.ratio ?? ImageMetricsStore.placeholderRatio
    }

    // MARK: Collection view

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { items.count }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: FilmstripCell.reuseID, for: indexPath) as! FilmstripCell
        cell.configure(with: items[indexPath.item], pixels: 256)
        cell.isCurrent = indexPath.item == selectedIndex
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, layout: UICollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> CGSize {
        let h = indexPath.item == selectedIndex ? selectedHeight : height
        let w = min(max(ratio(at: indexPath.item) * h, h * 0.5), h * 2.2)
        return CGSize(width: w.rounded(), height: h)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        onSelect?(indexPath.item)
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { isUserScrolling = true }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { isUserScrolling = false }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { isUserScrolling = false }
}

private final class FilmstripCell: UICollectionViewCell {
    static let reuseID = "FilmstripCell"

    private let imageView = UIImageView()
    /// Darkens the other thumbnails (fading them would let the transparency background show through).
    private let dim = UIView()
    private var token: LoadToken?
    private var url: URL?

    var isCurrent = false {
        didSet {
            contentView.layer.borderWidth = isCurrent ? 2 : 0
            dim.isHidden = isCurrent
            accessibilityTraits = isCurrent ? [.image, .selected] : .image
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.layer.cornerRadius = 8
        contentView.layer.cornerCurve = .continuous
        contentView.layer.borderColor = Theme.accent.cgColor
        contentView.clipsToBounds = true
        contentView.backgroundColor = .quaternarySystemFill
        imageView.contentMode = .scaleAspectFill
        imageView.frame = contentView.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(imageView)
        dim.backgroundColor = UIColor(white: 0, alpha: 0.45)
        dim.frame = contentView.bounds
        dim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(dim)
        isAccessibilityElement = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(with item: ImageItem, pixels: Int) {
        url = item.url
        accessibilityLabel = item.name
        contentView.backgroundColor = Settings.transparencyBackground.color
        // Any size already cached for the grid is good enough here.
        for bucket in ImagePipeline.thumbnailBuckets {
            if let image = ImagePipeline.thumbnails.cachedImage(for: .init(item, maxPixel: bucket)) {
                imageView.image = image
                return
            }
        }
        token = ImagePipeline.thumbnails.load(.init(item, maxPixel: pixels), priority: .low) { [weak self] image in
            guard let self, self.url == item.url else { return }
            self.imageView.image = image
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        ImagePipeline.thumbnails.cancel(token)
        token = nil
        url = nil
        imageView.image = nil
    }
}
