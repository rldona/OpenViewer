import UIKit

/// Image cell. Image loading is cancelled as soon as the cell is reused.
final class ThumbnailCell: UICollectionViewCell {
    static let reuseID = "ThumbnailCell"

    private let imageView = UIImageView()
    private let favoriteBadge = UIImageView(image: UIImage(systemName: "heart.fill",
                                                           withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold)))
    private let selectionDim = UIView()
    private let checkmark = UIImageView(image: UIImage(
        systemName: "checkmark.circle.fill",
        withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
            .applying(UIImage.SymbolConfiguration(paletteColors: [Theme.onAccent, Theme.accent]))))
    private var token: LoadToken?
    private var representedURL: URL?

    override init(frame: CGRect) {
        super.init(frame: frame)
        // A barely visible placeholder: a solid gray block flashes when many cells appear at once.
        contentView.backgroundColor = .quaternarySystemFill
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.frame = contentView.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(imageView)

        favoriteBadge.tintColor = .white
        favoriteBadge.layer.shadowColor = UIColor.black.cgColor
        favoriteBadge.layer.shadowOpacity = 0.5
        favoriteBadge.layer.shadowRadius = 2
        favoriteBadge.layer.shadowOffset = .zero
        favoriteBadge.isHidden = true
        favoriteBadge.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(favoriteBadge)
        selectionDim.backgroundColor = UIColor(white: 0, alpha: 0.25)
        selectionDim.isHidden = true
        selectionDim.frame = contentView.bounds
        selectionDim.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(selectionDim)
        checkmark.isHidden = true
        checkmark.layer.shadowColor = UIColor.black.cgColor
        checkmark.layer.shadowOpacity = 0.35
        checkmark.layer.shadowRadius = 2
        checkmark.layer.shadowOffset = .zero
        checkmark.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(checkmark)
        NSLayoutConstraint.activate([
            favoriteBadge.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 6),
            favoriteBadge.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
            checkmark.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -6),
            checkmark.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .image
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isHighlighted: Bool {
        didSet { contentView.alpha = isHighlighted ? 0.6 : 1 }
    }

    override var isSelected: Bool {
        didSet {
            checkmark.isHidden = !isSelected
            selectionDim.isHidden = !isSelected
            accessibilityTraits = isSelected ? [.image, .selected] : .image
        }
    }

    func configure(with item: ImageItem, pixelSize: Int) {
        representedURL = item.url
        accessibilityLabel = item.name
        updateFavorite()
        let request = ImagePipeline.Request(item, maxPixel: pixelSize)
        if let image = ImagePipeline.thumbnails.cachedImage(for: request) {
            setImage(image)
            return
        }
        // Show any size already in memory (e.g. from before a pinch) while the right one loads.
        if imageView.image == nil {
            for pixels in ImagePipeline.thumbnailBuckets.reversed() where pixels != pixelSize {
                if let image = ImagePipeline.thumbnails.cachedImage(for: .init(item, maxPixel: pixels)) {
                    setImage(image)
                    break
                }
            }
        }
        // When reconfigured for a new grid size the previous image stays visible until the new one arrives.
        ImagePipeline.thumbnails.cancel(token)
        token = ImagePipeline.thumbnails.load(request, priority: .high) { [weak self] image in
            guard let self, self.representedURL == item.url else { return }
            self.token = nil
            self.setImage(image)
        }
    }

    /// Transparent images show the chosen background; until an image arrives the cell keeps a faint placeholder.
    func updateBackground() {
        contentView.backgroundColor = imageView.image == nil || imageView.contentMode == .center
            ? .quaternarySystemFill : Settings.transparencyBackground.color
    }

    /// Visual confirmation of a long press (iPads have no haptic engine): a quick press-and-bounce.
    func pulse() {
        UIView.animate(withDuration: 0.1, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
            self.contentView.transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
        } completion: { _ in
            UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.45, initialSpringVelocity: 0,
                           options: [.allowUserInteraction]) {
                self.contentView.transform = .identity
            }
        }
    }

    func updateFavorite() {
        let isFavorite = representedURL.map(FavoritesStore.shared.contains) ?? false
        favoriteBadge.isHidden = !isFavorite
        accessibilityValue = isFavorite ? "Favorite" : nil
    }

    private func setImage(_ image: UIImage?) {
        if let image {
            imageView.contentMode = .scaleAspectFill
            imageView.tintColor = nil
            imageView.image = image
        } else {
            imageView.contentMode = .center
            imageView.tintColor = .tertiaryLabel
            imageView.image = UIImage(systemName: "exclamationmark.triangle")
        }
        updateBackground()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        ImagePipeline.thumbnails.cancel(token)
        token = nil
        representedURL = nil
        imageView.image = nil
        updateBackground()
    }
}

/// Folder card: cover thumbnail, name and a lazily computed summary.
final class FolderCell: UICollectionViewCell, UIContextMenuInteractionDelegate {
    static let reuseID = "FolderCell"

    /// Long-press menu. It lives on the cell (not the collection view) so long presses on images
    /// stay free for selection.
    var menuProvider: (() -> UIMenu?)?

    private let coverView = UIImageView()
    private let nameLabel = UILabel()
    private let favoriteBadge = UIImageView(image: UIImage(systemName: "heart.fill",
                                                           withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)))
    private let detailLabel = UILabel()
    private var token: LoadToken?
    private var representedURL: URL?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .secondarySystemGroupedBackground
        contentView.layer.cornerRadius = 12
        contentView.layer.cornerCurve = .continuous

        coverView.contentMode = .scaleAspectFill
        coverView.clipsToBounds = true
        coverView.layer.cornerRadius = 8
        coverView.layer.cornerCurve = .continuous
        coverView.backgroundColor = .tertiarySystemFill
        coverView.tintColor = .systemBlue

        nameLabel.font = .preferredFont(forTextStyle: .headline)
        nameLabel.adjustsFontForContentSizeCategory = true
        detailLabel.font = .preferredFont(forTextStyle: .subheadline)
        detailLabel.textColor = .secondaryLabel

        let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))
        chevron.tintColor = .tertiaryLabel
        chevron.setContentHuggingPriority(.required, for: .horizontal)

        favoriteBadge.tintColor = .systemPink
        favoriteBadge.isHidden = true
        favoriteBadge.setContentHuggingPriority(.required, for: .horizontal)
        let titleRow = UIStackView(arrangedSubviews: [nameLabel, favoriteBadge])
        titleRow.spacing = 6
        titleRow.alignment = .center
        let labels = UIStackView(arrangedSubviews: [titleRow, detailLabel])
        labels.axis = .vertical
        labels.spacing = 2
        let row = UIStackView(arrangedSubviews: [coverView, labels, chevron])
        row.alignment = .center
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        NSLayoutConstraint.activate([
            coverView.widthAnchor.constraint(equalToConstant: 52),
            coverView.heightAnchor.constraint(equalToConstant: 52),
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            row.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
        addInteraction(UIContextMenuInteraction(delegate: self))
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let menu = menuProvider?() else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in menu }
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, willDisplayMenuFor configuration: UIContextMenuConfiguration,
                                animator: UIContextMenuInteractionAnimating?) {
        // No-op on iPad hardware, which has no haptic engine; the menu's lift animation is the visual cue.
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isHighlighted: Bool {
        didSet { contentView.backgroundColor = isHighlighted ? .systemFill : .secondarySystemGroupedBackground }
    }

    func configure(with folder: FolderItem) {
        representedURL = folder.url
        nameLabel.text = folder.name
        updateFavorite()
        accessibilityLabel = folder.name
        if let info = FolderInfoCache.shared.cached(folder.url) {
            apply(info, for: folder.url)
        } else {
            detailLabel.text = " "
            showPlaceholder()
            FolderInfoCache.shared.info(for: folder.url) { [weak self] info in
                guard let self, self.representedURL == folder.url else { return }
                self.apply(info, for: folder.url)
            }
        }
    }

    func updateFavorite() {
        let isFavorite = representedURL.map(FavoriteFoldersStore.shared.contains) ?? false
        favoriteBadge.isHidden = !isFavorite
        accessibilityHint = isFavorite ? "Favorite folder" : nil
    }

    private func apply(_ info: FolderInfoCache.Info, for url: URL) {
        detailLabel.text = info.subtitle
        accessibilityValue = info.subtitle
        guard let cover = info.cover else { showPlaceholder(); return }
        let request = ImagePipeline.Request(cover, maxPixel: 256)
        if let image = ImagePipeline.thumbnails.cachedImage(for: request) {
            coverView.contentMode = .scaleAspectFill
            coverView.image = image
            return
        }
        showPlaceholder()
        token = ImagePipeline.thumbnails.load(request) { [weak self] image in
            guard let self, self.representedURL == url, let image else { return }
            self.coverView.contentMode = .scaleAspectFill
            self.coverView.image = image
        }
    }

    private func showPlaceholder() {
        coverView.contentMode = .center
        coverView.image = UIImage(systemName: "folder.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 22))
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        ImagePipeline.thumbnails.cancel(token)
        token = nil
        representedURL = nil
        coverView.image = nil
    }
}

/// Two-line navigation title: folder name + live status.
final class TitleView: UIView {
    let titleLabel = UILabel()
    let subtitleLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.textAlignment = .center
        subtitleLabel.font = .preferredFont(forTextStyle: .caption1)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.textAlignment = .center
        subtitleLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        let stack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}
