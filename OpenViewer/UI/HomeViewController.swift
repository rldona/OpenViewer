import UIKit
import UniformTypeIdentifiers

/// Start screen: open a folder or jump back into a recent one.
final class HomeViewController: UIViewController {
    private enum Section: Int, CaseIterable { case open, favoriteFolders, recent }

    private enum Row: Hashable {
        case pickFolder
        case appDocuments
        case favorites(Int)
        case favoriteFolder(FavoriteFolder)
        case recent(Bookmark)
    }

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Row>!
    private var didAttemptRestore = false

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "OpenViewer"
        view.backgroundColor = .systemGroupedBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "folder.badge.plus"), style: .plain, target: self, action: #selector(pickFolder))
        navigationItem.rightBarButtonItem?.accessibilityLabel = "Open Folder"

        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.headerMode = .supplementary
        config.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            guard let self else { return nil }
            let remove: UIContextualAction
            switch self.dataSource.itemIdentifier(for: indexPath) {
            case .recent(let bookmark):
                remove = UIContextualAction(style: .destructive, title: "Remove") { _, _, done in
                    BookmarkStore.shared.remove(bookmark.id)
                    self.reload()
                    done(true)
                }
            case .favoriteFolder(let folder):
                remove = UIContextualAction(style: .destructive, title: "Unfavorite") { _, _, done in
                    FavoriteFoldersStore.shared.remove(folder.id)
                    self.reload()
                    done(true)
                }
            default:
                return nil
            }
            return UISwipeActionsConfiguration(actions: [remove])
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
                content.secondaryText = "iCloud Drive, On My iPad, USB drives, servers (SMB) and more"
                content.image = UIImage(systemName: "folder.badge.plus")
            case .appDocuments:
                content.text = "On My iPad › OpenViewer"
                content.secondaryText = "Copy folders here with the Files app or Finder"
                content.image = UIImage(systemName: "ipad")
            case .favorites(let count):
                content.text = "Favorites"
                content.secondaryText = count == 0
                    ? "Tap ♥︎ in the viewer or press F to collect images here"
                    : "\(count.formatted()) image\(count == 1 ? "" : "s") from all your folders"
                content.image = UIImage(systemName: "heart.fill")
                content.imageProperties.tintColor = .systemPink
            case .favoriteFolder(let folder):
                content.text = folder.name
                content.secondaryText = URL(fileURLWithPath: folder.path).deletingLastPathComponent().lastPathComponent
                content.image = UIImage(systemName: "folder.fill")
                content.imageProperties.tintColor = .systemPink
            case .recent(let bookmark):
                content.text = bookmark.name
                content.secondaryText = "Opened " + bookmark.lastOpened.formatted(.relative(presentation: .named))
                content.image = UIImage(systemName: "folder.fill")
            }
            content.secondaryTextProperties.color = .secondaryLabel
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator()]
        }
        let headerRegistration = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] header, _, indexPath in
            var content = header.defaultContentConfiguration()
            let section = self?.dataSource.sectionIdentifier(for: indexPath.section)
            switch section {
            case .recent: content.text = "Recent"
            case .favoriteFolders: content.text = "Favorite Folders"
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
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Back at the root: nothing is being browsed any more.
        ScopedAccess.endAll()
        reload()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !didAttemptRestore {
            didAttemptRestore = true
            if Settings.reopenLastFolder, let last = BookmarkStore.shared.items.first {
                open(last, animated: false)
            }
        }
    }

    override var keyCommands: [UIKeyCommand]? {
        [UIKeyCommand(title: "Open Folder…", action: #selector(pickFolder), input: "o", modifierFlags: .command)]
    }

    private func reload() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Row>()
        snapshot.appendSections([.open])
        snapshot.appendItems([.pickFolder, .appDocuments, .favorites(FavoritesStore.shared.count)])
        let favoriteFolders = FavoriteFoldersStore.shared.items
        if !favoriteFolders.isEmpty {
            snapshot.appendSections([.favoriteFolders])
            snapshot.appendItems(favoriteFolders.map(Row.favoriteFolder))
        }
        let recents = BookmarkStore.shared.items
        if !recents.isEmpty {
            snapshot.appendSections([.recent])
            snapshot.appendItems(recents.map(Row.recent))
        }
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    @objc private func pickFolder() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.delegate = self
        picker.directoryURL = nil
        present(picker, animated: true)
    }

    private func open(_ bookmark: Bookmark, animated: Bool = true) {
        guard let url = BookmarkStore.shared.resolve(bookmark) else {
            let alert = UIAlertController(title: "Folder Unavailable",
                                          message: "“\(bookmark.name)” can't be reached. If it is on an external drive or server, connect it and try again.",
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
            return
        }
        BookmarkStore.shared.touch(bookmark.id)
        openFolder(url, animated: animated)
    }

    /// Favourites can live in any remembered folder, so access to all of them is opened.
    private func openFavorites() {
        beginAccessToRememberedFolders()
        navigationController?.pushViewController(BrowserViewController(favorites: ()), animated: true)
    }

    private func open(_ folder: FavoriteFolder) {
        beginAccessToRememberedFolders()
        let url = FavoriteFoldersStore.shared.resolve(folder)
        ScopedAccess.begin(url)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            let alert = UIAlertController(title: "Folder Unavailable",
                                          message: "“\(folder.name)” can't be reached. If it is on an external drive or server, connect it and try again.",
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
            return
        }
        navigationController?.pushViewController(BrowserViewController(folderURL: url, displayName: folder.name), animated: true)
    }

    private func beginAccessToRememberedFolders() {
        for bookmark in BookmarkStore.shared.items {
            if let url = BookmarkStore.shared.resolve(bookmark) { ScopedAccess.begin(url) }
        }
    }

    private func openFolder(_ url: URL, displayName: String? = nil, animated: Bool = true) {
        ScopedAccess.begin(url)
        navigationController?.pushViewController(BrowserViewController(folderURL: url, displayName: displayName), animated: animated)
    }
}

extension HomeViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .pickFolder:
            pickFolder()
        case .appDocuments:
            if let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                openFolder(docs, displayName: "On My iPad")
            }
        case .favorites:
            openFavorites()
        case .favoriteFolder(let folder):
            open(folder)
        case .recent(let bookmark):
            open(bookmark)
        case nil:
            break
        }
    }
}

extension HomeViewController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        if let bookmark = BookmarkStore.shared.add(url) {
            open(bookmark)
        } else {
            openFolder(url)
        }
    }
}
