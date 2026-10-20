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
    /// One small dot per colour tag.
    private let tagDots = UIStackView()

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
        tagDots.spacing = -3
        tagDots.isUserInteractionEnabled = false
        tagDots.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(tagDots)
        NSLayoutConstraint.activate([
            tagDots.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            tagDots.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -6),
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
        let tags = representedURL.map(TagStore.shared.tags(for:)) ?? []
        updateTagDots(tags)
        accessibilityValue = ([isFavorite ? "Favorite" : nil] + tags.map { "\($0.title) tag" }).compactMap { $0 }.joined(separator: ", ")
    }

    private func updateTagDots(_ tags: [TagColor]) {
        guard tagDots.arrangedSubviews.count != tags.count
                || zip(tagDots.arrangedSubviews, tags).contains(where: { $0.backgroundColor != $1.color }) else { return }
        tagDots.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for tag in tags {
            let dot = UIView()
            dot.backgroundColor = tag.color
            dot.layer.cornerRadius = 6
            dot.layer.borderWidth = 1.5
            dot.layer.borderColor = UIColor(white: 0, alpha: 0.35).cgColor
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.widthAnchor.constraint(equalToConstant: 12).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 12).isActive = true
            tagDots.addArrangedSubview(dot)
        }
    }

    private func setImage(_ image: UIImage?) {
        if let image {
            imageView.contentMode = .scaleAspectFill
            imageView.tintColor = nil
            imageView.image = image
            // Tiny images (pixel art, sprites) blown up to cell size stay crisp instead of blurry.
            let cellPixels = max(bounds.width, bounds.height) * traitCollection.displayScale
            let imagePixels = max(image.size.width, image.size.height) * image.scale
            imageView.layer.magnificationFilter = imagePixels > 0 && cellPixels / imagePixels >= 2 ? .nearest : .linear
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

/// Folder card: a mosaic of up to four images from inside the folder, its name and a summary.
final class FolderCell: UICollectionViewCell, UIContextMenuInteractionDelegate {
    static let reuseID = "FolderCell"

    /// Long-press menu. It lives on the cell (not the collection view) so long presses on images
    /// stay free for selection.
    var menuProvider: (() -> UIMenu?)?

    private let mosaic = MosaicView()
    private let tiles = (0..<4).map { _ in UIImageView() }
    private let placeholder = UIImageView(image: UIImage(systemName: "folder.fill",
                                                         withConfiguration: UIImage.SymbolConfiguration(pointSize: 34)))
    private let nameLabel = UILabel()
    private let favoriteBadge = UIImageView(image: UIImage(systemName: "heart.fill",
                                                           withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)))
    private let detailLabel = UILabel()
    private var tokens: [LoadToken] = []
    private var representedURL: URL?
    private var tileCount = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        mosaic.backgroundColor = .tertiarySystemFill
        mosaic.onLayout = { [weak self] in self?.layoutTiles() }
        mosaic.layer.cornerRadius = 14
        mosaic.layer.cornerCurve = .continuous
        mosaic.clipsToBounds = true
        for tile in tiles {
            tile.contentMode = .scaleAspectFill
            tile.clipsToBounds = true
            tile.backgroundColor = .quaternarySystemFill
            mosaic.addSubview(tile)
        }
        placeholder.tintColor = .tertiaryLabel
        placeholder.contentMode = .center
        mosaic.addSubview(placeholder)

        nameLabel.font = .preferredFont(forTextStyle: .headline)
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.font = .preferredFont(forTextStyle: .subheadline)
        detailLabel.textColor = .secondaryLabel

        favoriteBadge.tintColor = .systemPink
        favoriteBadge.isHidden = true
        favoriteBadge.setContentHuggingPriority(.required, for: .horizontal)
        let titleRow = UIStackView(arrangedSubviews: [nameLabel, favoriteBadge])
        titleRow.spacing = 6
        titleRow.alignment = .center
        let labels = UIStackView(arrangedSubviews: [titleRow, detailLabel])
        labels.axis = .vertical
        labels.spacing = 1
        labels.alignment = .leading
        labels.translatesAutoresizingMaskIntoConstraints = false
        mosaic.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(mosaic)
        contentView.addSubview(labels)
        NSLayoutConstraint.activate([
            mosaic.topAnchor.constraint(equalTo: contentView.topAnchor),
            mosaic.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            mosaic.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            mosaic.heightAnchor.constraint(equalTo: mosaic.widthAnchor, multiplier: 3.0 / 4.0),
            labels.topAnchor.constraint(equalTo: mosaic.bottomAnchor, constant: 8),
            labels.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 2),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor),
            titleRow.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
        addInteraction(UIContextMenuInteraction(delegate: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    /// 1 image fills the card, 2 split it, 3 = one tall + two stacked, 4 = a 2×2 grid.
    private func layoutTiles() {
        let bounds = mosaic.bounds
        let gap: CGFloat = 2
        let halfW = (bounds.width - gap) / 2, halfH = (bounds.height - gap) / 2
        let frames: [CGRect]
        switch tileCount {
        case 0: frames = []
        case 1: frames = [bounds]
        case 2: frames = [CGRect(x: 0, y: 0, width: halfW, height: bounds.height),
                          CGRect(x: halfW + gap, y: 0, width: halfW, height: bounds.height)]
        case 3: frames = [CGRect(x: 0, y: 0, width: halfW, height: bounds.height),
                          CGRect(x: halfW + gap, y: 0, width: halfW, height: halfH),
                          CGRect(x: halfW + gap, y: halfH + gap, width: halfW, height: halfH)]
        default: frames = [CGRect(x: 0, y: 0, width: halfW, height: halfH),
                           CGRect(x: halfW + gap, y: 0, width: halfW, height: halfH),
                           CGRect(x: 0, y: halfH + gap, width: halfW, height: halfH),
                           CGRect(x: halfW + gap, y: halfH + gap, width: halfW, height: halfH)]
        }
        for (index, tile) in tiles.enumerated() {
            tile.isHidden = index >= frames.count
            if index < frames.count { tile.frame = frames[index] }
        }
        placeholder.frame = bounds
        placeholder.isHidden = tileCount > 0
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

    override var isHighlighted: Bool {
        didSet { contentView.alpha = isHighlighted ? 0.6 : 1 }
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
            setTileCount(0)
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

    private func setTileCount(_ count: Int) {
        tileCount = count
        mosaic.setNeedsLayout()
    }

    private func apply(_ info: FolderInfoCache.Info, for url: URL) {
        detailLabel.text = info.subtitle
        accessibilityValue = info.subtitle
        setTileCount(info.covers.count)
        // Request each tile at its real on-screen size (a single cover fills the card).
        let tileWidth = info.covers.count == 1 ? bounds.width : bounds.width / 2
        let pixels = ImagePipeline.thumbnailBucket(forPixels: max(tileWidth, 120) * traitCollection.displayScale)
        let background = Settings.transparencyBackground.color
        tiles.forEach { $0.backgroundColor = background }
        for (index, cover) in info.covers.enumerated() {
            let tile = tiles[index]
            let request = ImagePipeline.Request(cover, maxPixel: pixels)
            if let image = ImagePipeline.thumbnails.cachedImage(for: request) {
                tile.image = image
                continue
            }
            tile.image = nil
            if let token = ImagePipeline.thumbnails.load(request, completion: { [weak self, weak tile] image in
                guard let self, self.representedURL == url else { return }
                tile?.image = image
            }) {
                tokens.append(token)
            }
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        tokens.forEach { ImagePipeline.thumbnails.cancel($0) }
        tokens.removeAll()
        representedURL = nil
        tiles.forEach { $0.image = nil }
        setTileCount(0)
    }
}

/// Navigation title: a tappable breadcrumb path to the current folder, plus a live status line.
final class TitleView: UIView {
    struct Crumb {
        let title: String
        let action: () -> Void
    }

    let titleLabel = UILabel()
    let subtitleLabel = UILabel()
    private let pathStack = UIStackView()

    /// How many ancestors stay visible; earlier ones fold into a "…" menu.
    private let visibleAncestors = 2

    override init(frame: CGRect) {
        super.init(frame: frame)
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.textAlignment = .center
        subtitleLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        pathStack.alignment = .center
        pathStack.spacing = 4
        let stack = UIStackView(arrangedSubviews: [pathStack, subtitleLabel])
        stack.axis = .vertical
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setPath(ancestors: [])
    }

    required init?(coder: NSCoder) { fatalError() }

    func setPath(ancestors: [Crumb]) {
        pathStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let hidden = ancestors.dropLast(visibleAncestors)
        let shown = ancestors.suffix(visibleAncestors)
        if !hidden.isEmpty {
            let more = crumbButton(title: "…")
            more.menu = UIMenu(children: hidden.reversed().map { crumb in
                UIAction(title: crumb.title, image: UIImage(systemName: "folder")) { _ in crumb.action() }
            })
            more.showsMenuAsPrimaryAction = true
            more.accessibilityLabel = "Earlier folders"
            pathStack.addArrangedSubview(more)
            pathStack.addArrangedSubview(chevron())
        }
        for crumb in shown {
            let button = crumbButton(title: crumb.title)
            button.addAction(UIAction { _ in crumb.action() }, for: .primaryActionTriggered)
            pathStack.addArrangedSubview(button)
            pathStack.addArrangedSubview(chevron())
        }
        pathStack.addArrangedSubview(titleLabel)
    }

    private func crumbButton(title: String) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.title = title
        config.baseForegroundColor = .secondaryLabel
        config.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: 2, bottom: 2, trailing: 2)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = .preferredFont(forTextStyle: .subheadline)
            return attributes
        }
        config.titleLineBreakMode = .byTruncatingTail
        let button = UIButton(configuration: config)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.widthAnchor.constraint(lessThanOrEqualToConstant: 180).isActive = true
        return button
    }

    private func chevron() -> UIImageView {
        let view = UIImageView(image: UIImage(systemName: "chevron.right",
                                              withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold)))
        view.tintColor = .tertiaryLabel
        view.setContentHuggingPriority(.required, for: .horizontal)
        return view
    }
}

/// Header above each folder's images in "All Images": folder name, its path and image count.
final class GroupHeaderView: UICollectionReusableView {
    static let reuseID = "GroupHeaderView"

    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        titleLabel.font = .systemFont(ofSize: 19, weight: .bold)
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        subtitleLabel.font = .preferredFont(forTextStyle: .subheadline)
        subtitleLabel.textColor = .secondaryLabel
        subtitleLabel.lineBreakMode = .byTruncatingHead
        let stack = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        stack.spacing = 10
        stack.alignment = .firstBaseline
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .header
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(title: String, subtitle: String) {
        titleLabel.text = title
        subtitleLabel.text = subtitle
        accessibilityLabel = "\(title), \(subtitle)"
    }
}

/// Lays out its tiles from its own final bounds. Doing it from the cell's layout pass read the
/// mosaic's previous size, so a reused cell kept tiles that left gaps at the right and bottom.
private final class MosaicView: UIView {
    var onLayout: (() -> Void)?

    override func layoutSubviews() {
        super.layoutSubviews()
        onLayout?()
    }
}
