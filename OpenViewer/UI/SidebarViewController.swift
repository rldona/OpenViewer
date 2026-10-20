import UIKit
import UniformTypeIdentifiers

/// The library: always-visible sidebar on iPad (open a folder, favourites, pinned folders, recents).
/// In a compact window the same list is the root screen and pushes folders onto its own stack.
final class SidebarViewController: UIViewController {
    private enum Section: Int, CaseIterable { case open, library, pinned, recent }

    private enum Row: Hashable {
        case pickFolder
        case favorites(Int)
        case appDocuments
        case favoriteFolder(FavoriteFolder)
        case recent(Bookmark)
    }

    /// The split view's detail stack; nil when this sidebar is the compact root and pushes instead.
    private weak var detailNavigation: UINavigationController?

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Row>!
    private var selectedRow: Row?
    private var didAttemptRestore = false

    init(detailNavigation: UINavigationController?) {
        self.detailNavigation = detailNavigation
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    private var showsSelection: Bool { detailNavigation != nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "OpenViewer"
        navigationItem.largeTitleDisplayMode = .always
        let openButton = UIBarButtonItem(
            image: UIImage(systemName: "folder.badge.plus"), style: .plain, target: self, action: #selector(pickFolder))
        openButton.accessibilityLabel = "Open Folder"
        let settingsButton = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), menu: makeSettingsMenu())
        settingsButton.accessibilityLabel = "Settings"
        navigationItem.rightBarButtonItems = [settingsButton, openButton]

        var config = UICollectionLayoutListConfiguration(appearance: showsSelection ? .sidebar : .insetGrouped)
        config.headerMode = .supplementary
        config.backgroundColor = showsSelection ? Theme.sidebarBackground : nil
        config.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            self?.swipeActions(at: indexPath)
        }
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: UICollectionViewCompositionalLayout.list(using: config))
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.delegate = self
        view.addSubview(collectionView)

        let cellRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, Row> { cell, _, row in
            var content = cell.defaultContentConfiguration()
            switch row {
            case .pickFolder:
                content.text = "Open Folder…"
                content.textProperties.color = Theme.accent
                content.textProperties.font = .preferredFont(forTextStyle: .headline)
                content.image = UIImage(systemName: "folder.badge.plus")
            case .favorites(let count):
                content.text = "Favorites"
                content.secondaryText = count == 0 ? nil : count.formatted()
                content.image = UIImage(systemName: "heart.fill")
                content.imageProperties.tintColor = .systemPink
            case .appDocuments:
                content.text = "On My iPad"
                content.image = UIImage(systemName: "ipad")
            case .favoriteFolder(let folder):
                content.text = folder.name
                content.image = UIImage(systemName: "folder.fill")
                content.imageProperties.tintColor = .systemPink
            case .recent(let bookmark):
                content.text = bookmark.name
                content.image = UIImage(systemName: "folder.fill")
            }
            content.prefersSideBySideTextAndSecondaryText = true
            content.secondaryTextProperties.color = .secondaryLabel
            cell.contentConfiguration = content
            cell.accessories = []
        }
        let headerRegistration = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] header, _, indexPath in
            var content = UIListContentConfiguration.sidebarHeader()
            switch self?.dataSource.sectionIdentifier(for: indexPath.section) {
            case .library: content.text = "Library"
            case .pinned: content.text = "Pinned Folders"
            case .recent: content.text = "Recent"
            default: content.text = nil
            }
            header.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { cv, indexPath, row in
            cv.dequeueConfiguredReusableCell(using: cellRegistration, for: indexPath, item: row)
        }
        dataSource.supplementaryViewProvider = { cv, _, indexPath in
            cv.dequeueConfiguredReusableSupplementary(using: headerRegistration, for: indexPath)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(libraryChanged),
                                               name: FavoritesStore.didChange, object: nil)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if !showsSelection {
            // Compact root: back here means nothing is being browsed any more.
            ScopedAccess.endAll()
        }
        reload()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didAttemptRestore else { return }
        didAttemptRestore = true
        if Settings.reopenLastFolder, let last = BookmarkStore.shared.items.first {
            open(.recent(last), animated: false)
        }
    }

    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(title: "Open Folder…", action: #selector(pickFolder), input: "o", modifierFlags: .command)]
    }

    // MARK: Data

    @objc private func libraryChanged() { reload() }

    private func reload() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Row>()
        snapshot.appendSections([.open, .library])
        snapshot.appendItems([.pickFolder], toSection: .open)
        snapshot.appendItems([.favorites(FavoritesStore.shared.count), .appDocuments], toSection: .library)
        let pinned = FavoriteFoldersStore.shared.items
        if !pinned.isEmpty {
            snapshot.appendSections([.pinned])
            snapshot.appendItems(pinned.map(Row.favoriteFolder), toSection: .pinned)
        }
        let recents = BookmarkStore.shared.items
        if !recents.isEmpty {
            snapshot.appendSections([.recent])
            snapshot.appendItems(recents.map(Row.recent), toSection: .recent)
        }
        dataSource.apply(snapshot, animatingDifferences: false)
        restoreSelection()
    }

    /// Keeps the open location highlighted; favourites' count changes the row identity, so match by kind.
    private func restoreSelection() {
        guard showsSelection, let selectedRow else { return }
        let match = dataSource.snapshot().itemIdentifiers.first { row in
            switch (row, selectedRow) {
            case (.favorites, .favorites), (.appDocuments, .appDocuments): return true
            case let (.favoriteFolder(a), .favoriteFolder(b)): return a.id == b.id
            case let (.recent(a), .recent(b)): return a.id == b.id
            default: return false
            }
        }
        if let match, let indexPath = dataSource.indexPath(for: match) {
            collectionView.selectItem(at: indexPath, animated: false, scrollPosition: [])
        }
    }

    private func swipeActions(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let action: UIContextualAction
        switch dataSource.itemIdentifier(for: indexPath) {
        case .recent(let bookmark):
            action = UIContextualAction(style: .destructive, title: "Remove") { [weak self] _, _, done in
                BookmarkStore.shared.remove(bookmark.id)
                self?.reload()
                done(true)
            }
        case .favoriteFolder(let folder):
            action = UIContextualAction(style: .destructive, title: "Unpin") { [weak self] _, _, done in
                FavoriteFoldersStore.shared.remove(folder.id)
                self?.reload()
                done(true)
            }
        default:
            return nil
        }
        return UISwipeActionsConfiguration(actions: [action])
    }

    private func makeSettingsMenu() -> UIMenu {
        let current = Appearance.current
        let appearance = Appearance.allCases.map { option in
            UIAction(title: option.title, state: option == current ? .on : .off) { [weak self] _ in
                Appearance.current = option
                self?.navigationItem.rightBarButtonItems?.first?.menu = self?.makeSettingsMenu()
            }
        }
        return UIMenu(children: [
            UIMenu(title: "Appearance", subtitle: current.title, image: UIImage(systemName: "circle.lefthalf.filled"), children: appearance),
        ])
    }

    // MARK: Opening

    @objc func pickFolder() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.delegate = self
        present(picker, animated: true)
    }

    private func open(_ row: Row, animated: Bool = true) {
        switch row {
        case .pickFolder:
            pickFolder()
        case .favorites:
            show(BrowserViewController(favorites: ()), row: row, accessAll: true, animated: animated)
        case .appDocuments:
            if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                show(BrowserViewController(folderURL: docs, displayName: "On My iPad"), row: row, animated: animated)
            }
        case .favoriteFolder(let folder):
            let url = FavoriteFoldersStore.shared.resolve(folder)
            var isDirectory: ObjCBool = false
            ScopedAccess.endAll()
            beginAccessToRememberedFolders()
            ScopedAccess.begin(url)
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                showUnavailable(folder.name)
                return
            }
            show(BrowserViewController(folderURL: url, displayName: folder.name), row: row, root: url, accessAll: true, animated: animated)
        case .recent(let bookmark):
            guard let url = BookmarkStore.shared.resolve(bookmark) else {
                showUnavailable(bookmark.name)
                return
            }
            BookmarkStore.shared.touch(bookmark.id)
            show(BrowserViewController(folderURL: url), row: .recent(bookmark), root: url, animated: animated)
        }
    }

    /// Replaces the detail column (regular width) or pushes (compact) the given browser.
    private func show(_ browser: BrowserViewController, row: Row, root: URL? = nil,
                      accessAll: Bool = false, animated: Bool) {
        if let detailNavigation {
            ScopedAccess.endAll()
            if accessAll { beginAccessToRememberedFolders() }
            if let root { ScopedAccess.begin(root) }
            selectedRow = row
            detailNavigation.setViewControllers([browser], animated: false)
            splitViewController?.show(.secondary)
            reload()
        } else {
            if accessAll { beginAccessToRememberedFolders() }
            if let root { ScopedAccess.begin(root) }
            navigationController?.pushViewController(browser, animated: animated)
        }
    }

    private func beginAccessToRememberedFolders() {
        for bookmark in BookmarkStore.shared.items {
            if let url = BookmarkStore.shared.resolve(bookmark) { ScopedAccess.begin(url) }
        }
    }

    private func showUnavailable(_ name: String) {
        let alert = UIAlertController(title: "Folder Unavailable",
                                      message: "“\(name)” can't be reached. If it is on an external drive or server, connect it and try again.",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
        restoreSelection()
    }
}

extension SidebarViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let row = dataSource.itemIdentifier(for: indexPath) else { return }
        if !showsSelection || row == .pickFolder {
            collectionView.deselectItem(at: indexPath, animated: true)
        }
        if row == .pickFolder { restoreSelection() }
        open(row)
    }
}

extension SidebarViewController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        if let bookmark = BookmarkStore.shared.add(url) {
            open(.recent(bookmark))
        } else {
            ScopedAccess.begin(url)
            show(BrowserViewController(folderURL: url), row: .pickFolder, root: url, animated: true)
        }
    }
}

/// Shown in the detail column until a location is chosen.
final class EmptyLibraryViewController: UIViewController {
    var onOpenFolder: (() -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.background
        let icon = UIImageView(image: UIImage(systemName: "photo.stack", withConfiguration: UIImage.SymbolConfiguration(pointSize: 56, weight: .light)))
        icon.tintColor = .tertiaryLabel
        let title = UILabel()
        title.text = "Open a folder to start"
        title.font = .preferredFont(forTextStyle: .title2)
        let detail = UILabel()
        detail.text = "iCloud Drive, On My iPad, USB drives, servers (SMB) and more"
        detail.font = .preferredFont(forTextStyle: .subheadline)
        detail.textColor = .secondaryLabel
        var config = UIButton.Configuration.filled()
        config.title = "Open Folder…"
        config.baseBackgroundColor = Theme.accent
        config.baseForegroundColor = Theme.onAccent
        config.cornerStyle = .capsule
        config.buttonSize = .large
        let button = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in self?.onOpenFolder?() })
        let stack = UIStackView(arrangedSubviews: [icon, title, detail, button])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 12
        stack.setCustomSpacing(24, after: detail)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }
}
