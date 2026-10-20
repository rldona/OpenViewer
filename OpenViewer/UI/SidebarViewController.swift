import UIKit
import UniformTypeIdentifiers

/// The library: always-visible sidebar on iPad (open a folder, favourites, pinned folders, recents).
/// In a compact window the same list is the root screen and pushes folders onto its own stack.
final class SidebarViewController: UIViewController {
    private enum Section: String, CaseIterable {
        case library, pinned, smartAlbums, boards, tags, recent

        var title: String {
            switch self {
            case .boards: return "Boards"
            case .library: return "Library"
            case .smartAlbums: return "Smart Albums"
            case .tags: return "Tags"
            case .pinned: return "Pinned Folders"
            case .recent: return "Recent"
            }
        }
    }

    private enum Row: Hashable {
        /// Collapsible section title (Photos-style chevron).
        case header(Section)
        case pickFolder
        case favorites(Int)
        case appDocuments
        case favoriteFolder(FavoriteFolder)
        case smartAlbum(SmartAlbum)
        case board(UUID, String, Int)
        case tag(TagColor, Int)
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

    deinit { ScopedAccess.endAll(owner: self) }

    private var showsSelection: Bool { detailNavigation != nil }

    /// Opens a folder directly (e.g. in a window opened with "Open in New Window").
    func openFolder(_ url: URL) {
        ScopedAccess.begin(url, owner: self)
        if let bookmark = BookmarkStore.shared.items.first(where: { BookmarkStore.shared.resolve($0)?.standardizedFileURL == url.standardizedFileURL }) {
            open(.recent(bookmark), animated: false)
        } else {
            show(BrowserViewController(folderURL: url), row: .pickFolder, root: url, accessAll: true, animated: false)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "OpenViewer"
        // A small title leaves the room for the library itself.
        navigationItem.largeTitleDisplayMode = .never
        let openButton = UIBarButtonItem(
            image: UIImage(systemName: "folder.badge.plus"), style: .plain, target: self, action: #selector(pickFolder))
        openButton.accessibilityLabel = "Open Folder"
        let settingsButton = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), menu: makeSettingsMenu())
        settingsButton.accessibilityLabel = "Settings"
        navigationItem.rightBarButtonItems = [settingsButton, openButton]

        var config = UICollectionLayoutListConfiguration(appearance: showsSelection ? .sidebar : .insetGrouped)
        config.headerMode = .firstItemInSection
        if showsSelection {
            // Clear on iOS 26 so the system's floating glass sidebar shows the grid through it.
            if #available(iOS 26.0, *) {
                config.backgroundColor = .clear
            } else {
                config.backgroundColor = Theme.sidebarBackground
            }
        }
        config.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            self?.swipeActions(at: indexPath)
        }
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: UICollectionViewCompositionalLayout.list(using: config))
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.delegate = self
        collectionView.allowsSelectionDuringEditing = false
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
            case .smartAlbum(let album):
                content.text = album.name
                content.image = UIImage(systemName: "gearshape.2.fill")
                content.imageProperties.tintColor = Theme.accent
            case .board(_, let name, let count):
                content.text = name
                content.secondaryText = count.formatted()
                content.image = UIImage(systemName: "rectangle.on.rectangle.angled")
                content.imageProperties.tintColor = Theme.accent
            case .tag(let tag, let count):
                content.text = tag.title
                content.secondaryText = count.formatted()
                content.image = UIImage(systemName: "circle.fill")
                content.imageProperties.tintColor = tag.color
            case .header:
                break
            }
            content.prefersSideBySideTextAndSecondaryText = true
            content.secondaryTextProperties.color = .secondaryLabel
            cell.contentConfiguration = content
            // In edit mode (like Photos): pinned folders get a grip to drag; both lists can remove rows.
            switch row {
            case .favoriteFolder, .smartAlbum, .board:
                cell.accessories = [.delete(displayed: .whenEditing), .reorder(displayed: .whenEditing)]
            case .recent:
                cell.accessories = [.delete(displayed: .whenEditing)]
            default:
                cell.accessories = []
            }
        }
        let headerRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, Section> { cell, _, section in
            var content = UIListContentConfiguration.sidebarHeader()
            content.text = section.title
            cell.contentConfiguration = content
            cell.accessories = [.outlineDisclosure(options: .init(style: .header))]
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { cv, indexPath, row in
            if case .header(let section) = row {
                return cv.dequeueConfiguredReusableCell(using: headerRegistration, for: indexPath, item: section)
            }
            return cv.dequeueConfiguredReusableCell(using: cellRegistration, for: indexPath, item: row)
        }
        dataSource.sectionSnapshotHandlers.willCollapseItem = { row in
            if case .header(let section) = row { Self.setCollapsed(section, true) }
        }
        dataSource.sectionSnapshotHandlers.willExpandItem = { row in
            if case .header(let section) = row { Self.setCollapsed(section, false) }
        }
        dataSource.reorderingHandlers.canReorderItem = { row in
            switch row {
            case .favoriteFolder, .smartAlbum, .board: return true
            default: return false
            }
        }
        dataSource.reorderingHandlers.didReorder = { transaction in
            let rows = transaction.finalSnapshot.itemIdentifiers
            FavoriteFoldersStore.shared.reorder(rows.compactMap { row -> UUID? in
                if case .favoriteFolder(let folder) = row { return folder.id }
                return nil
            })
            SmartAlbumStore.shared.reorder(rows.compactMap { row -> UUID? in
                if case .smartAlbum(let album) = row { return album.id }
                return nil
            })
            BoardStore.shared.reorder(rows.compactMap { row -> UUID? in
                if case .board(let id, _, _) = row { return id }
                return nil
            })
        }
        NotificationCenter.default.addObserver(self, selector: #selector(libraryChanged),
                                               name: FavoritesStore.didChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(libraryChanged),
                                               name: TagStore.didChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(libraryChanged),
                                               name: BoardStore.didChange, object: nil)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if !showsSelection {
            // Compact root: back here means nothing is being browsed any more.
            ScopedAccess.endAll(owner: self)
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

    private static let collapsedKey = "sidebarCollapsedSections"

    private static func isCollapsed(_ section: Section) -> Bool {
        (UserDefaults.standard.array(forKey: collapsedKey) as? [String] ?? []).contains(section.rawValue)
    }

    private static func setCollapsed(_ section: Section, _ collapsed: Bool) {
        var set = Set(UserDefaults.standard.array(forKey: collapsedKey) as? [String] ?? [])
        if collapsed { set.insert(section.rawValue) } else { set.remove(section.rawValue) }
        UserDefaults.standard.set(Array(set), forKey: collapsedKey)
    }

    private func reload() {
        let contents: [(Section, [Row])] = [
            (.library, [.favorites(FavoritesStore.shared.count), .appDocuments]),
            (.pinned, FavoriteFoldersStore.shared.items.map(Row.favoriteFolder)),
            (.smartAlbums, SmartAlbumStore.shared.items.map(Row.smartAlbum)),
            (.boards, BoardStore.shared.boards.map { Row.board($0.id, $0.name, $0.items.count) }),
            (.tags, TagStore.shared.counts.map { Row.tag($0.tag, $0.count) }),
            (.recent, BookmarkStore.shared.items.map(Row.recent)),
        ].filter { !$0.1.isEmpty }

        let sections = contents.map(\.0)
        if dataSource.snapshot().sectionIdentifiers != sections {
            var snapshot = NSDiffableDataSourceSnapshot<Section, Row>()
            snapshot.appendSections(sections)
            dataSource.apply(snapshot, animatingDifferences: false)
        }
        for (section, rows) in contents {
            var sectionSnapshot = NSDiffableDataSourceSectionSnapshot<Row>()
            let header = Row.header(section)
            sectionSnapshot.append([header])
            sectionSnapshot.append(rows, to: header)
            if !Self.isCollapsed(section) { sectionSnapshot.expand([header]) }
            dataSource.apply(sectionSnapshot, to: section, animatingDifferences: false)
        }
        restoreSelection()
    }

    override func setEditing(_ editing: Bool, animated: Bool) {
        super.setEditing(editing, animated: animated)
        collectionView.isEditing = editing
        // Only "Done" while editing; otherwise the small title keeps the top-left corner.
        navigationItem.setLeftBarButton(editing ? editButtonItem : nil, animated: animated)
        if !editing { restoreSelection() }
    }

    /// Keeps the open location highlighted; favourites' count changes the row identity, so match by kind.
    private func restoreSelection() {
        guard showsSelection, let selectedRow else { return }
        let match = dataSource.snapshot().itemIdentifiers.first { row in
            switch (row, selectedRow) {
            case (.favorites, .favorites), (.appDocuments, .appDocuments): return true
            case let (.favoriteFolder(a), .favoriteFolder(b)): return a.id == b.id
            case let (.recent(a), .recent(b)): return a.id == b.id
            case let (.smartAlbum(a), .smartAlbum(b)): return a.id == b.id
            case let (.board(a, _, _), .board(b, _, _)): return a == b
            case let (.tag(a, _), .tag(b, _)): return a == b
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
        case .smartAlbum(let album):
            action = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, done in
                SmartAlbumStore.shared.remove(album.id)
                self?.reload()
                done(true)
            }
        case .board(let id, _, _):
            action = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, done in
                BoardStore.shared.remove(id)
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
        let edit = UIAction(title: "Edit Sidebar", image: UIImage(systemName: "list.bullet")) { [weak self] _ in
            self?.setEditing(true, animated: true)
        }
        let newBoard = UIAction(title: "New Board", image: UIImage(systemName: "rectangle.on.rectangle.angled")) { [weak self] _ in
            self?.promptNewBoard()
        }
        return UIMenu(children: [
            newBoard,
            edit,
            UIMenu(title: "Appearance", subtitle: current.title, image: UIImage(systemName: "circle.lefthalf.filled"), children: appearance),
        ])
    }

    private func promptNewBoard() {
        BoardPrompt.create(from: self) { [weak self] board in
            self?.open(.board(board.id, board.name, 0))
        }
    }

    // MARK: Opening

    @objc func pickFolder() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.delegate = self
        present(picker, animated: true)
    }

    private func open(_ row: Row, animated: Bool = true) {
        switch row {
        case .header:
            break
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
            ScopedAccess.endAll(owner: self)
            beginAccessToRememberedFolders()
            ScopedAccess.begin(url, owner: self)
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                showUnavailable(folder.name)
                return
            }
            show(BrowserViewController(folderURL: url, displayName: folder.name), row: row, root: url, accessAll: true, animated: animated)
        case .smartAlbum(let album):
            let url = SmartAlbumStore.shared.resolve(album)
            ScopedAccess.endAll(owner: self)
            beginAccessToRememberedFolders()
            ScopedAccess.begin(url, owner: self)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                showUnavailable(album.name)
                return
            }
            show(BrowserViewController(folderURL: url, smartAlbum: album), row: row, root: url, accessAll: true, animated: animated)
        case .board(let id, _, _):
            guard let board = BoardStore.shared.board(id) else { return }
            show(BoardViewController(board: board), row: row, accessAll: true, animated: animated)
        case .tag(let tag, _):
            let collection = ImageCollection(title: "\(tag.title) Tag", images: [], source: { TagStore.shared.urls(for: tag) })
            show(BrowserViewController(collection: collection), row: row, accessAll: true, animated: animated)
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
    private func show(_ browser: UIViewController, row: Row, root: URL? = nil,
                      accessAll: Bool = false, animated: Bool) {
        if let detailNavigation {
            ScopedAccess.endAll(owner: self)
            if accessAll { beginAccessToRememberedFolders() }
            if let root { ScopedAccess.begin(root, owner: self) }
            selectedRow = row
            detailNavigation.setViewControllers([browser], animated: false)
            splitViewController?.show(.secondary)
            reload()
        } else {
            if accessAll { beginAccessToRememberedFolders() }
            if let root { ScopedAccess.begin(root, owner: self) }
            navigationController?.pushViewController(browser, animated: animated)
        }
    }

    private func beginAccessToRememberedFolders() {
        for bookmark in BookmarkStore.shared.items {
            if let url = BookmarkStore.shared.resolve(bookmark) { ScopedAccess.begin(url, owner: self) }
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
    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
                        point: CGPoint) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first, let row = dataSource.itemIdentifier(for: indexPath) else { return nil }
        let url: URL?
        switch row {
        case .favoriteFolder(let folder): url = FavoriteFoldersStore.shared.resolve(folder)
        case .smartAlbum(let album): url = SmartAlbumStore.shared.resolve(album)
        case .recent(let bookmark): url = BookmarkStore.shared.resolve(bookmark)
        default: url = nil
        }
        guard let url, UIApplication.shared.supportsMultipleScenes else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            UIMenu(children: [UIAction(title: "Open in New Window", image: UIImage(systemName: "macwindow.badge.plus")) { _ in
                WindowOpener.open(url)
            }])
        }
    }

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        if case .header = dataSource.itemIdentifier(for: indexPath) { return false }
        return true
    }

    /// Pinned folders only move among themselves, below their header.
    func collectionView(_ collectionView: UICollectionView,
                        targetIndexPathForMoveOfItemFromOriginalIndexPath originalIndexPath: IndexPath,
                        atCurrentIndexPath currentIndexPath: IndexPath,
                        toProposedIndexPath proposedIndexPath: IndexPath) -> IndexPath {
        guard proposedIndexPath.section == originalIndexPath.section else { return currentIndexPath }
        return IndexPath(item: max(proposedIndexPath.item, 1), section: proposedIndexPath.section)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let row = dataSource.itemIdentifier(for: indexPath) else { return }
        if case .header = row { return }
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
            ScopedAccess.begin(url, owner: self)
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
