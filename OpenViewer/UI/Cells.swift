import UIKit

/// Square image cell. Image loading is cancelled as soon as the cell is reused.
final class ThumbnailCell: UICollectionViewCell {
    static let reuseID = "ThumbnailCell"

    private let imageView = UIImageView()
    private var token: LoadToken?
    private var representedURL: URL?

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.backgroundColor = .secondarySystemFill
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.frame = contentView.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(imageView)
        isAccessibilityElement = true
        accessibilityTraits = .image
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isHighlighted: Bool {
        didSet { contentView.alpha = isHighlighted ? 0.6 : 1 }
    }

    func configure(with item: ImageItem, pixelSize: Int) {
        representedURL = item.url
        accessibilityLabel = item.name
        let request = ImagePipeline.Request(item, maxPixel: pixelSize)
        if let image = ImagePipeline.thumbnails.cachedImage(for: request) {
            setImage(image)
            return
        }
        // When reconfigured for a new grid size the previous image stays visible until the new one arrives.
        ImagePipeline.thumbnails.cancel(token)
        token = ImagePipeline.thumbnails.load(request, priority: .high) { [weak self] image in
            guard let self, self.representedURL == item.url else { return }
            self.token = nil
            self.setImage(image)
        }
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
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        ImagePipeline.thumbnails.cancel(token)
        token = nil
        representedURL = nil
        imageView.image = nil
    }
}

/// Folder card: cover thumbnail, name and a lazily computed summary.
final class FolderCell: UICollectionViewCell {
    static let reuseID = "FolderCell"

    private let coverView = UIImageView()
    private let nameLabel = UILabel()
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

        let labels = UIStackView(arrangedSubviews: [nameLabel, detailLabel])
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
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isHighlighted: Bool {
        didSet { contentView.backgroundColor = isHighlighted ? .systemFill : .secondarySystemGroupedBackground }
    }

    func configure(with folder: FolderItem) {
        representedURL = folder.url
        nameLabel.text = folder.name
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
