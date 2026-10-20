import UIKit

/// Grid of a folder's subfolders and images, or — with "Include Subfolders" — every image in the tree.
final class BrowserViewController: UIViewController {
    /// Target thumbnail widths in points for each grid zoom level.
    static let gridLevels: [CGFloat] = [72, 100, 140, 190, 260, 360]

    private enum Section: Int, CaseIterable { case folders, images }

    private final class CancelFlag { var cancelled = false }

    let folderURL: URL
    private let displayName: String

    private var collectionView: UICollectionView!
    private let titleView = TitleView()
    private let emptyLabel = UILabel()

    private var allFolders: [FolderItem] = []
    private var allImages: [ImageItem] = []
    private var folders: [FolderItem] = []
    private var images: [ImageItem] = []
    private var query = ""
    private var isScanning = false
    private var scanFlag: CancelFlag?

    private var includeSubfolders = Settings.includeSubfolders
    private var gridLevel = min(max(Settings.gridLevel, 0), BrowserViewController.gridLevels.count - 1)
    private var thumbnailPixels = 256
    private var prefetchTokens: [IndexPath: LoadToken] = [:]
    private var menuButton: UIBarButtonItem!

    init(folderURL: URL, displayName: String? = nil) {
        self.folderURL = folderURL
        self.displayName = displayName ?? folderURL.lastPathComponent
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { scanFlag?.cancelled = true }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.largeTitleDisplayMode = .never
        titleView.titleLabel.text = displayName
        navigationItem.titleView = titleView
        title = displayName

        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: makeLayout())
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .systemBackground
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.prefetchDataSource = self
        collectionView.dragDelegate = self
        collectionView.keyboardDismissMode = .onDrag
        collectionView.register(ThumbnailCell.self, forCellWithReuseIdentifier: ThumbnailCell.reuseID)
        collectionView.register(FolderCell.self, forCellWithReuseIdentifier: FolderCell.reuseID)
        collectionView.addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:))))
        view.addSubview(collectionView)

        emptyLabel.textColor = .secondaryLabel
        emptyLabel.textAlignment = .center
        emptyLabel.numberOfLines = 0
        emptyLabel.font = .preferredFont(forTextStyle: .title3)

        let search = UISearchController(searchResultsController: nil)
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = "Filter by name"
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = true
        definesPresentationContext = true

        menuButton = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), menu: makeMenu())
        menuButton.accessibilityLabel = "View Options"
        let slideshow = UIBarButtonItem(image: UIImage(systemName: "play.rectangle"), style: .plain,
                                        target: self, action: #selector(startSlideshow))
        slideshow.accessibilityLabel = "Slideshow"
        navigationItem.rightBarButtonItems = [menuButton, slideshow]

        reload()
    }

    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(title: "Larger Thumbnails", action: #selector(zoomIn), input: "+", modifierFlags: .command),
            UIKeyCommand(title: "Larger Thumbnails", action: #selector(zoomIn), input: "=", modifierFlags: .command),
            UIKeyCommand(title: "Smaller Thumbnails", action: #selector(zoomOut), input: "-", modifierFlags: .command),
            UIKeyCommand(title: "Include Subfolders", action: #selector(toggleSubfolders), input: "r", modifierFlags: .command),
            UIKeyCommand(title: "Search", action: #selector(focusSearch), input: "f", modifierFlags: .command),
            UIKeyCommand(title: "Slideshow", action: #selector(startSlideshow), input: "p", modifierFlags: .command),
            UIKeyCommand(title: "Back", action: #selector(goBack), input: UIKeyCommand.inputLeftArrow, modifierFlags: .command),
        ]
    }

    // MARK: Loading

    private func reload() {
        scanFlag?.cancelled = true
        let flag = CancelFlag()
        scanFlag = flag
        let url = folderURL
        let order = Settings.sortOrder
        let recursive = includeSubfolders
        isScanning = true
        updateStatus()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            if !recursive {
                let listing = FolderScanner.list(url)
                let folders = listing.folders.sorted(by: SortOrder(key: order.key == .size ? .name : order.key, ascending: order.ascending))
                let images = listing.images.sorted(by: order)
                DispatchQueue.main.async {
                    guard let self, !flag.cancelled else { return }
                    self.isScanning = false
                    self.setContent(folders: folders, images: images)
                }
                return
            }

            var found: [ImageItem] = []
            FolderScanner.scanRecursively(url, isCancelled: { flag.cancelled }) { batch in
                found.append(contentsOf: batch)
                let snapshot = found
                DispatchQueue.main.async {
                    guard let self, !flag.cancelled else { return }
                    self.setContent(folders: [], images: snapshot)
                }
            }
            guard !flag.cancelled else { return }
            let sorted = found.sorted(by: order, byPath: true)
            DispatchQueue.main.async {
                guard let self, !flag.cancelled else { return }
                self.isScanning = false
                self.setContent(folders: [], images: sorted)
            }
        }
    }

    /// Re-sorts what is already loaded without touching the file system.
    private func resort() {
        guard !isScanning else { reload(); return }
        let order = Settings.sortOrder
        let recursive = includeSubfolders
        let folders = allFolders
        let images = allImages
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let sortedFolders = folders.sorted(by: SortOrder(key: order.key == .size ? .name : order.key, ascending: order.ascending))
            let sortedImages = images.sorted(by: order, byPath: recursive)
            DispatchQueue.main.async {
                self?.setContent(folders: sortedFolders, images: sortedImages)
            }
        }
    }

    private func setContent(folders: [FolderItem], images: [ImageItem]) {
        allFolders = folders
        allImages = images
        applyFilter()
    }

    private func applyFilter() {
        if query.isEmpty {
            folders = allFolders
            images = allImages
        } else {
            folders = allFolders.filter { $0.name.localizedCaseInsensitiveContains(query) }
            images = allImages.filter { $0.name.localizedCaseInsensitiveContains(query) }
        }
        prefetchTokens.values.forEach { ImagePipeline.thumbnails.cancel($0) }
        prefetchTokens.removeAll()
        collectionView.reloadData()
        updateStatus()
    }

    private func updateStatus() {
        var parts: [String] = []
        if !folders.isEmpty { parts.append("\(folders.count.formatted()) folder\(folders.count == 1 ? "" : "s")") }
        parts.append("\(images.count.formatted()) image\(images.count == 1 ? "" : "s")")
        if isScanning { parts.append(includeSubfolders ? "scanning…" : "loading…") }
        if includeSubfolders { parts.insert("All subfolders", at: 0) }
        titleView.subtitleLabel.text = parts.joined(separator: " · ")

        if !isScanning && folders.isEmpty && images.isEmpty {
            emptyLabel.text = query.isEmpty ? "No images here" : "No matches for “\(query)”"
            collectionView.backgroundView = emptyLabel
        } else {
            collectionView.backgroundView = nil
        }
    }

    // MARK: Layout

    private func makeLayout() -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { [weak self] sectionIndex, environment in
            guard let self else { return nil }
            let width = environment.container.effectiveContentSize.width
            switch Section(rawValue: sectionIndex)! {
            case .folders:
                let columns = max(1, Int(width / 320))
                let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(1 / CGFloat(columns)),
                                                                    heightDimension: .fractionalHeight(1)))
                let group = NSCollectionLayoutGroup.horizontal(layoutSize: .init(widthDimension: .fractionalWidth(1),
                                                                                 heightDimension: .absolute(72)),
                                                               repeatingSubitem: item, count: columns)
                group.interItemSpacing = .fixed(10)
                let section = NSCollectionLayoutSection(group: group)
                section.interGroupSpacing = 10
                section.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 16, bottom: 16, trailing: 16)
                return section

            case .images:
                let spacing: CGFloat = 2
                let target = Self.gridLevels[self.gridLevel]
                let columns = max(2, Int(((width + spacing) / (target + spacing)).rounded()))
                let cellWidth = (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
                self.thumbnailPixels = ImagePipeline.thumbnailBucket(forPixels: cellWidth * self.traitCollection.displayScale)

                let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(1 / CGFloat(columns)),
                                                                    heightDimension: .fractionalHeight(1)))
                let group = NSCollectionLayoutGroup.horizontal(layoutSize: .init(widthDimension: .fractionalWidth(1),
                                                                                 heightDimension: .absolute(cellWidth)),
                                                               repeatingSubitem: item, count: columns)
                group.interItemSpacing = .fixed(spacing)
                let section = NSCollectionLayoutSection(group: group)
                section.interGroupSpacing = spacing
                return section
            }
        }
    }

    private func setGridLevel(_ level: Int) {
        let clamped = min(max(level, 0), Self.gridLevels.count - 1)
        guard clamped != gridLevel else { return }
        gridLevel = clamped
        Settings.gridLevel = clamped
        let oldPixels = thumbnailPixels
        UIView.animate(withDuration: 0.25) {
            self.collectionView.collectionViewLayout.invalidateLayout()
            self.collectionView.layoutIfNeeded()
        }
        if thumbnailPixels != oldPixels {
            let visible = collectionView.indexPathsForVisibleItems.filter { $0.section == Section.images.rawValue }
            collectionView.reconfigureItems(at: visible)
        }
        menuButton.menu = makeMenu()
    }

    @objc private func handlePinch(_ pinch: UIPinchGestureRecognizer) {
        guard pinch.state == .changed else { return }
        if pinch.scale > 1.3 {
            setGridLevel(gridLevel + 1)
            pinch.scale = 1
        } else if pinch.scale < 0.75 {
            setGridLevel(gridLevel - 1)
            pinch.scale = 1
        }
    }

    @objc private func zoomIn() { setGridLevel(gridLevel + 1) }
    @objc private func zoomOut() { setGridLevel(gridLevel - 1) }
    @objc private func focusSearch() { navigationItem.searchController?.searchBar.becomeFirstResponder() }
    @objc private func goBack() { navigationController?.popViewController(animated: true) }

    // MARK: Menu

    private func makeMenu() -> UIMenu {
        let order = Settings.sortOrder
        let sortActions = SortKey.allCases.map { key in
            UIAction(title: key.title, state: order.key == key ? .on : .off) { [weak self] _ in
                Settings.sortOrder = SortOrder(key: key, ascending: order.ascending)
                self?.menuButton.menu = self?.makeMenu()
                self?.resort()
            }
        }
        let directionActions = [true, false].map { ascending in
            UIAction(title: ascending ? "Ascending" : "Descending", state: order.ascending == ascending ? .on : .off) { [weak self] _ in
                Settings.sortOrder = SortOrder(key: order.key, ascending: ascending)
                self?.menuButton.menu = self?.makeMenu()
                self?.resort()
            }
        }
        let recursive = UIAction(title: "Include Subfolders", subtitle: "Show every image in this folder tree",
                                 image: UIImage(systemName: "square.stack.3d.down.right"),
                                 state: includeSubfolders ? .on : .off) { [weak self] _ in
            self?.toggleSubfolders()
        }
        let larger = UIAction(title: "Larger Thumbnails", image: UIImage(systemName: "plus.magnifyingglass"),
                              attributes: gridLevel == Self.gridLevels.count - 1 ? .disabled : []) { [weak self] _ in self?.zoomIn() }
        let smaller = UIAction(title: "Smaller Thumbnails", image: UIImage(systemName: "minus.magnifyingglass"),
                               attributes: gridLevel == 0 ? .disabled : []) { [weak self] _ in self?.zoomOut() }
        let refresh = UIAction(title: "Refresh", image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in
            FolderInfoCache.shared.invalidate()
            self?.reload()
        }
        return UIMenu(children: [
            UIMenu(options: .displayInline, children: [recursive]),
            UIMenu(title: "Sort By", image: UIImage(systemName: "arrow.up.arrow.down"), children: [
                UIMenu(options: .displayInline, children: sortActions),
                UIMenu(options: .displayInline, children: directionActions),
            ]),
            UIMenu(options: .displayInline, children: [larger, smaller]),
            UIMenu(options: .displayInline, children: [refresh]),
        ])
    }

    @objc private func toggleSubfolders() {
        includeSubfolders.toggle()
        Settings.includeSubfolders = includeSubfolders
        menuButton.menu = makeMenu()
        setContent(folders: [], images: [])
        collectionView.setContentOffset(CGPoint(x: 0, y: -collectionView.adjustedContentInset.top), animated: false)
        reload()
    }

    // MARK: Viewer

    @objc private func startSlideshow() {
        guard !images.isEmpty else { return }
        openViewer(at: 0, slideshow: true)
    }

    private func openViewer(at index: Int, slideshow: Bool = false) {
        let items = images
        let viewer = ViewerViewController(items: items, index: index, startSlideshow: slideshow)
        viewer.modalPresentationStyle = .fullScreen

        let options = UIViewController.Transition.ZoomOptions()
        options.interactiveDismissShouldBegin = { [weak viewer] _ in viewer?.canInteractivelyDismiss ?? true }
        viewer.preferredTransition = .zoom(options: options) { [weak self] context in
            guard let self, let viewer = context.zoomedViewController as? ViewerViewController else { return nil }
            let index = viewer.currentIndex
            // The list may have changed (e.g. a recursive scan finished) while the viewer was open.
            guard index < self.images.count, self.images[index].url == items[index].url else { return nil }
            let indexPath = IndexPath(item: index, section: Section.images.rawValue)
            if !self.collectionView.indexPathsForVisibleItems.contains(indexPath) {
                self.collectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: false)
                self.collectionView.layoutIfNeeded()
            }
            return self.collectionView.cellForItem(at: indexPath)
        }

        var presenter: UIViewController = self
        while let presented = presenter.presentedViewController { presenter = presented }
        presenter.present(viewer, animated: true)
    }
}

// MARK: - Data source

extension BrowserViewController: UICollectionViewDataSource {
    func numberOfSections(in collectionView: UICollectionView) -> Int { Section.allCases.count }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        Section(rawValue: section) == .folders ? folders.count : images.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        if Section(rawValue: indexPath.section) == .folders {
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: FolderCell.reuseID, for: indexPath) as! FolderCell
            cell.configure(with: folders[indexPath.item])
            return cell
        }
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: ThumbnailCell.reuseID, for: indexPath) as! ThumbnailCell
        cell.configure(with: images[indexPath.item], pixelSize: thumbnailPixels)
        return cell
    }
}

extension BrowserViewController: UICollectionViewDataSourcePrefetching {
    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        for indexPath in indexPaths where indexPath.section == Section.images.rawValue && indexPath.item < images.count {
            guard prefetchTokens[indexPath] == nil else { continue }
            let request = ImagePipeline.Request(images[indexPath.item], maxPixel: thumbnailPixels)
            if let token = ImagePipeline.thumbnails.load(request, priority: .low, completion: { [weak self] _ in
                self?.prefetchTokens[indexPath] = nil
            }) {
                prefetchTokens[indexPath] = token
            }
        }
    }

    func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
        for indexPath in indexPaths {
            ImagePipeline.thumbnails.cancel(prefetchTokens.removeValue(forKey: indexPath))
        }
    }
}

// MARK: - Delegate

extension BrowserViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        switch Section(rawValue: indexPath.section)! {
        case .folders:
            navigationController?.pushViewController(BrowserViewController(folderURL: folders[indexPath.item].url), animated: true)
        case .images:
            openViewer(at: indexPath.item)
        }
    }

    func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemsAt indexPaths: [IndexPath],
                        point: CGPoint) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first else { return nil }
        let url = indexPath.section == Section.folders.rawValue ? folders[indexPath.item].url : images[indexPath.item].url
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            let share = UIAction(title: "Share", image: UIImage(systemName: "square.and.arrow.up")) { _ in
                guard let self, let cell = collectionView.cellForItem(at: indexPath) else { return }
                let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                activity.popoverPresentationController?.sourceView = cell
                self.present(activity, animated: true)
            }
            let copyName = UIAction(title: "Copy Name", image: UIImage(systemName: "doc.on.doc")) { _ in
                UIPasteboard.general.string = url.lastPathComponent
            }
            return UIMenu(children: [share, copyName])
        }
    }
}

extension BrowserViewController: UICollectionViewDragDelegate {
    func collectionView(_ collectionView: UICollectionView, itemsForBeginning session: UIDragSession,
                        at indexPath: IndexPath) -> [UIDragItem] {
        guard indexPath.section == Section.images.rawValue,
              let provider = NSItemProvider(contentsOf: images[indexPath.item].url) else { return [] }
        provider.suggestedName = images[indexPath.item].name
        return [UIDragItem(itemProvider: provider)]
    }
}

extension BrowserViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        let text = searchController.searchBar.text?.trimmingCharacters(in: .whitespaces) ?? ""
        guard text != query else { return }
        query = text
        applyFilter()
    }
}
