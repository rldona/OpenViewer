import os
import UIKit

/// Grid of a folder's subfolders and images, or — with "Include Subfolders" — every image in the tree.
final class BrowserViewController: UIViewController {
    /// Row height (justified grid) or cell width (square grid), in points, for each zoom level.
    static let gridLevels: [CGFloat] = [80, 110, 150, 200, 280, 380]

    private enum Section: Int, CaseIterable { case folders, images }

    private final class CancelFlag { var cancelled = false }

    /// `nil` for the cross-folder Favorites view.
    let folderURL: URL?
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
    /// True while a cached tree is on screen and being checked for changes in the background.
    private var isRevalidating = false
    /// Recursive results in tree order (each folder's images, then its subfolders, by name).
    private var treeOrder: [ImageItem] = []
    private var scanFlag: CancelFlag?

    private var includeSubfolders = Settings.includeSubfolders
    private var gridLevel = min(max(Settings.gridLevel, 0), BrowserViewController.gridLevels.count - 1)
    private let layout = GalleryLayout()
    /// Aspect ratio of each entry in `images`; placeholders until resolved.
    private var ratios: [CGFloat] = []
    private var resolver: MetricsResolver?
    /// Images that pass the name and favourites filters, before the size filter. The metrics resolver works on these.
    private var baseImages: [ImageItem] = []
    /// `images[i] == baseImages[sourceIndices[i]]`, so visible items can be prioritised by the resolver.
    private var sourceIndices: [Int] = []
    private var hiddenSmallCount = 0
    private var hiddenEmptyFolderCount = 0
    private var hideEmptyFolders = Settings.hideEmptyFolders
    private var folderRefilterScheduled = false
    /// Filtering runs here so huge lists never block the main thread.
    private let filterQueue = DispatchQueue(label: "openviewer.filter", qos: .userInitiated)
    private var filterGeneration = 0
    /// Latest requested generation, readable from the filter queue.
    private let latestFilter = OSAllocatedUnfairLock(initialState: 0)
    private var lastResolverStart: CFAbsoluteTime = 0
    private var minimumSide = Settings.minimumImageSide
    private var contentGeneration = 0
    private var prefetchTokens: [IndexPath: LoadToken] = [:]
    private var menuButton: UIBarButtonItem!
    private var normalRightItems: [UIBarButtonItem] = []
    private var slideshowButton: UIBarButtonItem!
    private var selectButton: UIBarButtonItem!

    // Selection mode
    private(set) var isSelecting = false
    private var selectedURLs = Set<URL>()
    private let selectionLabel = UILabel()
    private var shareSelectionButton: UIBarButtonItem!
    private var favoriteSelectionButton: UIBarButtonItem!
    private var folderSelectionButton: UIBarButtonItem!
    private var compareSelectionButton: UIBarButtonItem!
    /// Sources of a "Copy to…" / "Move to…" in progress, and whether it moves them.
    private var pendingExport: (sources: [URL], isMove: Bool)?
    /// Photos-style swipe selection: a horizontal drag selects (or deselects) the range it covers.
    private let selectionPan = UIPanGestureRecognizer()
    /// Google Photos-style: long-press an image to start selecting, then keep the finger down and drag.
    private let selectionLongPress = UILongPressGestureRecognizer()
    private var dragSelection: (start: Int, last: Int, selecting: Bool, original: Set<URL>)?
    private var autoScrollLink: CADisplayLink?
    private var autoScrollSpeed: CGFloat = 0
    private var lastPanLocation: CGPoint = .zero

    init(folderURL: URL, displayName: String? = nil) {
        self.folderURL = folderURL
        self.displayName = displayName ?? folderURL.lastPathComponent
        super.init(nibName: nil, bundle: nil)
    }

    /// Every favourite image across all folders.
    init(favorites: ()) {
        self.folderURL = nil
        self.displayName = "Favorites"
        super.init(nibName: nil, bundle: nil)
    }

    private var isFavoritesView: Bool { folderURL == nil }
    private var favoritesOnly = false
    private var showsOnlyFavorites: Bool { favoritesOnly || isFavoritesView }
    private var needsRefilter = false

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        scanFlag?.cancelled = true
        resolver?.cancel()
    }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.largeTitleDisplayMode = .never
        titleView.titleLabel.text = displayName
        navigationItem.titleView = titleView
        title = displayName

        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .systemBackground
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.prefetchDataSource = self
        // Long press is used for selection, which would conflict with lifting items to drag them.
        collectionView.dragInteractionEnabled = false
        collectionView.keyboardDismissMode = .onDrag
        collectionView.register(ThumbnailCell.self, forCellWithReuseIdentifier: ThumbnailCell.reuseID)
        collectionView.register(FolderCell.self, forCellWithReuseIdentifier: FolderCell.reuseID)
        collectionView.addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:))))
        view.addSubview(collectionView)
        layout.style = Settings.gridStyle
        layout.targetSize = Self.gridLevels[gridLevel]

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
        slideshowButton = UIBarButtonItem(image: UIImage(systemName: "play.rectangle"), style: .plain,
                                        target: self, action: #selector(startSlideshow))
        slideshowButton.accessibilityLabel = "Slideshow"
        selectButton = UIBarButtonItem(title: "Select", style: .plain, target: self, action: #selector(enterSelection))
        normalRightItems = [menuButton, slideshowButton, selectButton]
        navigationItem.rightBarButtonItems = normalRightItems
        collectionView.allowsMultipleSelectionDuringEditing = true
        selectionPan.addTarget(self, action: #selector(handleSelectionPan(_:)))
        selectionPan.delegate = self
        selectionLongPress.addTarget(self, action: #selector(handleSelectionLongPress(_:)))
        selectionLongPress.minimumPressDuration = 0.3
        selectionLongPress.delegate = self
        collectionView.addGestureRecognizer(selectionLongPress)
        collectionView.addGestureRecognizer(selectionPan)
        setupSelectionToolbar()

        NotificationCenter.default.addObserver(self, selector: #selector(favoritesChanged(_:)),
                                               name: FavoritesStore.didChange, object: nil)
        NotificationCenter.default.addObserver(forName: TransparencyBackground.didChange, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            for case let cell as ThumbnailCell in self.collectionView.visibleCells { cell.updateBackground() }
            self.menuButton.menu = self.makeMenu()
        }
        reload()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if needsRefilter {
            needsRefilter = false
            applyFilter()
        }
    }

    @objc private func favoritesChanged(_ notification: Notification) {
        menuButton.menu = makeMenu()
        for case let cell as FolderCell in collectionView.visibleCells { cell.updateFavorite() }
        guard showsOnlyFavorites else {
            for case let cell as ThumbnailCell in collectionView.visibleCells { cell.updateFavorite() }
            return
        }
        // Don't reshuffle the grid under the viewer; refilter once it is back on screen.
        if presentedViewController != nil {
            needsRefilter = true
        } else {
            applyFilter()
        }
    }

    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(title: "Larger Thumbnails", action: #selector(zoomIn), input: "+", modifierFlags: .command),
            UIKeyCommand(title: "Larger Thumbnails", action: #selector(zoomIn), input: "=", modifierFlags: .command),
            UIKeyCommand(title: "Smaller Thumbnails", action: #selector(zoomOut), input: "-", modifierFlags: .command),
            UIKeyCommand(title: "Include Subfolders", action: #selector(toggleSubfolders), input: "r", modifierFlags: .command),
            UIKeyCommand(title: "Favorites Only", action: #selector(toggleFavoritesOnly), input: "l", modifierFlags: .command),
            UIKeyCommand(title: "Search", action: #selector(focusSearch), input: "f", modifierFlags: .command),
            UIKeyCommand(title: "Slideshow", action: #selector(startSlideshow), input: "p", modifierFlags: .command),
            UIKeyCommand(title: "Back", action: #selector(goBack), input: UIKeyCommand.inputLeftArrow, modifierFlags: .command),
            UIKeyCommand(title: "Select All", action: #selector(selectAllFromKeyboard), input: "a", modifierFlags: .command),
        ] + (isSelecting ? [UIKeyCommand(title: "Done", action: #selector(exitSelection), input: UIKeyCommand.inputEscape)] : [])
    }

    // MARK: Loading

    private func reload() {
        scanFlag?.cancelled = true
        let flag = CancelFlag()
        scanFlag = flag
        let order = Settings.sortOrder
        isScanning = true
        updateStatus()

        guard let url = folderURL else {
            let favorites = FavoritesStore.shared.urls
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                // Files on drives or servers that are not connected right now are skipped.
                let images = favorites.compactMap { url -> ImageItem? in
                    guard let values = try? url.resourceValues(forKeys: FolderScanner.keys), values.isDirectory != true else { return nil }
                    return ImageItem(url: url, size: values.fileSize ?? 0, modified: values.contentModificationDate ?? .distantPast)
                }.sorted(by: order, byPath: true)
                DispatchQueue.main.async {
                    guard let self, !flag.cancelled else { return }
                    self.isScanning = false
                    self.setContent(folders: [], images: images)
                }
            }
            return
        }
        let recursive = includeSubfolders

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

            // 1. Show the last known tree instantly.
            let previous = ScanCache.load(root: url)
            if let previous {
                let cached = previous.images(root: url)
                let ordered = Self.ordered(cached, by: order)
                DispatchQueue.main.async {
                    guard let self, !flag.cancelled else { return }
                    self.isRevalidating = true
                    self.treeOrder = cached
                    self.setContent(folders: [], images: ordered)
                }
            }

            // 2. Revalidate in the background, re-listing only folders that changed.
            let result = IncrementalScanner.scan(root: url, previous: previous, isCancelled: { flag.cancelled }) { partial in
                guard previous == nil else { return }
                DispatchQueue.main.async {
                    guard let self, !flag.cancelled else { return }
                    self.treeOrder = partial
                    self.setContent(folders: [], images: partial)
                }
            }
            guard let result, !flag.cancelled else { return }
            let changed = previous == nil || result.changedDirectories > 0
            if changed { ScanCache.save(result.snapshot, root: url) }
            let ordered = changed ? Self.ordered(result.images, by: order) : nil
            DispatchQueue.main.async {
                guard let self, !flag.cancelled else { return }
                self.isScanning = false
                self.isRevalidating = false
                if let ordered {
                    self.treeOrder = result.images
                    self.setContent(folders: [], images: ordered)
                } else {
                    self.updateStatus()
                    self.startResolverIfNeeded(force: true)
                }
            }
        }
    }

    /// Name order comes straight from the tree walk; other orders are sorted (numeric, cheap).
    private static func ordered(_ treeOrder: [ImageItem], by order: SortOrder) -> [ImageItem] {
        guard order.key != .name else { return order.ascending ? treeOrder : treeOrder.reversed() }
        return treeOrder.sorted(by: order)
    }

    /// Re-sorts what is already loaded without touching the file system.
    private func resort() {
        guard !isScanning else { reload(); return }
        let order = Settings.sortOrder
        let fromTree = includeSubfolders && !isFavoritesView
        let folders = allFolders
        let images = fromTree ? treeOrder : allImages
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let sortedFolders = folders.sorted(by: SortOrder(key: order.key == .size ? .name : order.key, ascending: order.ascending))
            let sortedImages = fromTree ? Self.ordered(images, by: order) : images.sorted(by: order, byPath: self?.isFavoritesView ?? false)
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

    /// Rebuilds the visible lists from `allImages` on a background queue and applies the result.
    /// Requests that arrive while one is running supersede it.
    private func applyFilter(keepPosition: Bool = false, restartResolver: Bool = true) {
        filterGeneration += 1
        let generation = filterGeneration
        latestFilter.withLock { $0 = generation }
        let latestFilter = self.latestFilter
        let allImages = self.allImages
        let allFolders = self.allFolders
        let query = self.query
        let favoriteKeys: Set<String>? = showsOnlyFavorites ? FavoritesStore.shared.keys : nil
        let minimumSide = self.minimumSide
        let isFavoritesView = self.isFavoritesView
        let emptyFolders = hideEmptyFolders ? knownEmptyFolders() : []

        filterQueue.async { [weak self] in
            // A newer request is already queued: skip this one.
            guard latestFilter.withLock({ $0 }) == generation else { return }

            var folders = query.isEmpty ? allFolders : allFolders.filter { $0.name.localizedCaseInsensitiveContains(query) }
            if isFavoritesView { folders = [] }
            let foldersBeforeHiding = folders.count
            if !emptyFolders.isEmpty { folders.removeAll { emptyFolders.contains($0.url) } }
            let hiddenEmpty = foldersBeforeHiding - folders.count

            var base: [ImageItem] = []
            base.reserveCapacity(favoriteKeys == nil ? allImages.count : 64)
            for item in allImages {
                if let favoriteKeys, !favoriteKeys.contains(FavoritesStore.key(path: item.url.path)) { continue }
                if !query.isEmpty && !item.name.localizedCaseInsensitiveContains(query) { continue }
                base.append(item)
            }

            let store = ImageMetricsStore.shared
            var images: [ImageItem] = []
            var sourceIndices: [Int] = []
            var ratios: [CGFloat] = []
            var hidden = 0
            images.reserveCapacity(base.count)
            for (index, item) in base.enumerated() {
                let metrics = store.metrics(for: item.url)
                // Unknown sizes stay visible until the resolver has read them.
                if minimumSide > 0, let metrics, metrics.maxSide > 0, metrics.maxSide < minimumSide {
                    hidden += 1
                    continue
                }
                images.append(item)
                sourceIndices.append(index)
                ratios.append(metrics?.ratio ?? ImageMetricsStore.placeholderRatio)
            }

            DispatchQueue.main.async {
                guard let self, self.filterGeneration == generation else { return }
                self.hiddenEmptyFolderCount = hiddenEmpty
                self.applyFiltered(folders: folders, base: base, images: images, sourceIndices: sourceIndices,
                                   ratios: ratios, hidden: hidden, keepPosition: keepPosition)
                if restartResolver { self.startResolverIfNeeded() }
            }
        }
    }

    private func applyFiltered(folders: [FolderItem], base: [ImageItem], images: [ImageItem], sourceIndices: [Int],
                               ratios: [CGFloat], hidden: Int, keepPosition: Bool) {
        let sameList = folders.count == self.folders.count && images.count == self.images.count
            && images.first?.url == self.images.first?.url && images.last?.url == self.images.last?.url
        self.baseImages = base
        self.sourceIndices = sourceIndices
        self.hiddenSmallCount = hidden
        self.folders = folders

        if keepPosition && sameList {
            // Only proportions changed: relayout in place.
            self.images = images
            self.ratios = ratios
            relayoutKeepingPosition(animated: false) { self.layout.ratios = ratios }
            updateStatus()
            return
        }

        let offsetY = collectionView.contentOffset.y
        let atTop = offsetY <= -collectionView.adjustedContentInset.top + 1
        let anchorIndex = keepPosition
            ? collectionView.indexPathsForVisibleItems.filter { $0.section == Section.images.rawValue }.map(\.item).min()
            : nil
        let anchorURL = anchorIndex.flatMap { self.images.indices.contains($0) ? self.images[$0].url : nil }
        let oldMinY = anchorIndex.flatMap { layout.imageFrame(at: $0)?.minY }

        self.images = images
        self.ratios = ratios
        prefetchTokens.values.forEach { ImagePipeline.thumbnails.cancel($0) }
        prefetchTokens.removeAll()
        layout.ratios = ratios
        collectionView.reloadData()
        restoreSelection()
        updateStatus()

        guard keepPosition, !atTop, let anchorURL, let oldMinY else { return }
        collectionView.layoutIfNeeded()
        guard let newIndex = images.firstIndex(where: { $0.url == anchorURL }),
              let newMinY = layout.imageFrame(at: newIndex)?.minY else { return }
        let maxOffset = max(-collectionView.adjustedContentInset.top,
                            collectionView.contentSize.height - collectionView.bounds.height + collectionView.adjustedContentInset.bottom)
        collectionView.contentOffset.y = min(offsetY + newMinY - oldMinY, maxOffset)
    }

    // MARK: Empty folders

    /// Folders already known to contain no images; asks for the unknown ones and refilters as answers arrive.
    private func knownEmptyFolders() -> Set<URL> {
        var empty = Set<URL>()
        let cache = FolderInfoCache.shared
        for folder in allFolders {
            if let info = cache.cached(folder.url) {
                if !info.containsImages { empty.insert(folder.url) }
            } else {
                cache.info(for: folder.url) { [weak self] info in
                    if !info.containsImages { self?.scheduleFolderRefilter() }
                }
            }
        }
        return empty
    }

    /// Coalesces many folder answers into one refilter.
    private func scheduleFolderRefilter() {
        guard !folderRefilterScheduled else { return }
        folderRefilterScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            self.folderRefilterScheduled = false
            if self.hideEmptyFolders { self.applyFilter(keepPosition: true, restartResolver: false) }
        }
    }

    @objc private func toggleHideEmptyFolders() {
        hideEmptyFolders.toggle()
        Settings.hideEmptyFolders = hideEmptyFolders
        menuButton.menu = makeMenu()
        applyFilter(keepPosition: true, restartResolver: false)
    }

    // MARK: Image metrics

    private var needsMetrics: Bool { layout.style == .justified || minimumSide > 0 }

    /// Reads unknown image sizes from file headers in the background, visible items first.
    /// While a big tree is still being scanned it restarts at most every few seconds.
    private func startResolverIfNeeded(force: Bool = false) {
        let now = CFAbsoluteTimeGetCurrent()
        if isScanning && !force && resolver != nil && now - lastResolverStart < 3 { return }
        resolver?.cancel()
        resolver = nil
        contentGeneration += 1
        guard needsMetrics, !baseImages.isEmpty else { return }
        lastResolverStart = now
        let generation = contentGeneration
        let resolver = MetricsResolver(urls: baseImages.map(\.url)) { [weak self] in
            guard let self, generation == self.contentGeneration else { return }
            self.applyFilter(keepPosition: true, restartResolver: false)
        }
        self.resolver = resolver
        prioritizeVisible()
        resolver.start()
    }

    private func prioritizeVisible() {
        guard let resolver else { return }
        guard let visible = visibleImageRange(), !visible.isEmpty, visible.upperBound <= sourceIndices.count else {
            resolver.prioritize(0..<min(baseImages.count, 120))
            return
        }
        let low = sourceIndices[visible.lowerBound]
        let high = sourceIndices[visible.upperBound - 1]
        resolver.prioritize(low..<(high + 1))
    }

    private func visibleImageRange(margin: Int = 60) -> Range<Int>? {
        let visible = collectionView.indexPathsForVisibleItems.filter { $0.section == Section.images.rawValue }.map(\.item)
        guard let low = visible.min(), let high = visible.max() else { return nil }
        return max(0, low - margin)..<min(images.count, high + margin + 1)
    }

    /// Applies a layout change while keeping the first visible image where it is on screen.
    private func relayoutKeepingPosition(animated: Bool, _ change: @escaping () -> Void) {
        let offsetY = collectionView.contentOffset.y
        let atTop = offsetY <= -collectionView.adjustedContentInset.top + 1
        let anchor = collectionView.indexPathsForVisibleItems.filter { $0.section == Section.images.rawValue }.min()
        let oldMinY = anchor.flatMap { layout.imageFrame(at: $0.item)?.minY }

        let apply = {
            change()
            self.collectionView.layoutIfNeeded()
            if !atTop, let anchor, let oldMinY, let newMinY = self.layout.imageFrame(at: anchor.item)?.minY {
                let maxOffset = max(-self.collectionView.adjustedContentInset.top,
                                    self.collectionView.contentSize.height - self.collectionView.bounds.height
                                        + self.collectionView.adjustedContentInset.bottom)
                self.collectionView.contentOffset.y = min(offsetY + newMinY - oldMinY, maxOffset)
            }
        }
        if animated {
            UIView.animate(withDuration: 0.25, animations: apply)
        } else {
            apply()
        }
        let visible = collectionView.indexPathsForVisibleItems.filter { $0.section == Section.images.rawValue }
        collectionView.reconfigureItems(at: visible)
    }

    private func thumbnailPixels(for index: Int) -> Int {
        let frame = layout.imageFrame(at: index) ?? CGRect(x: 0, y: 0, width: 150, height: 150)
        return ImagePipeline.thumbnailBucket(forPixels: max(frame.width, frame.height) * traitCollection.displayScale)
    }

    private func updateStatus() {
        var parts: [String] = []
        if !folders.isEmpty { parts.append("\(folders.count.formatted()) folder\(folders.count == 1 ? "" : "s")") }
        if showsImageControls || !images.isEmpty || folders.isEmpty {
            parts.append("\(images.count.formatted()) image\(images.count == 1 ? "" : "s")")
        }
        if hiddenEmptyFolderCount > 0 { parts.append("\(hiddenEmptyFolderCount.formatted()) empty hidden") }
        if hiddenSmallCount > 0 { parts.append("\(hiddenSmallCount.formatted()) small hidden") }
        if isRevalidating {
            parts.append("checking for changes…")
        } else if isScanning {
            parts.append(includeSubfolders ? "scanning…" : "loading…")
        }
        if includeSubfolders && !isFavoritesView { parts.insert("All subfolders", at: 0) }
        if favoritesOnly { parts.insert("Favorites", at: 0) }
        titleView.subtitleLabel.text = parts.joined(separator: " · ")

        if !isScanning && folders.isEmpty && images.isEmpty {
            if !query.isEmpty {
                emptyLabel.text = "No matches for “\(query)”"
            } else if showsOnlyFavorites {
                emptyLabel.text = "No favorites yet\nTap ♥︎ in the viewer, press F, or long-press a thumbnail."
            } else {
                emptyLabel.text = "No images here"
            }
            collectionView.backgroundView = emptyLabel
        } else {
            collectionView.backgroundView = nil
        }
        if isSelecting { updateSelectionUI() }
        updateContextualControls()
    }

    // MARK: Layout

    private func setGridLevel(_ level: Int) {
        let clamped = min(max(level, 0), Self.gridLevels.count - 1)
        guard clamped != gridLevel else { return }
        gridLevel = clamped
        Settings.gridLevel = clamped
        relayoutKeepingPosition(animated: true) { self.layout.targetSize = Self.gridLevels[clamped] }
        menuButton.menu = makeMenu()
    }

    private func setGridStyle(_ style: GalleryLayout.Style) {
        guard style != layout.style else { return }
        Settings.gridStyle = style
        relayoutKeepingPosition(animated: true) { self.layout.style = style }
        menuButton.menu = makeMenu()
        startResolverIfNeeded(force: true)
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
        let imageContext = showsImageControls
        // Folders have no size, so that order is only offered when images are shown.
        let sortKeys = imageContext ? SortKey.allCases : [.name, .date]
        let sortActions = sortKeys.map { key in
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
        let favoritesOnlyAction = UIAction(title: "Favorites Only", image: UIImage(systemName: "heart"),
                                           state: favoritesOnly ? .on : .off) { [weak self] _ in
            self?.toggleFavoritesOnly()
        }
        let styleActions = [
            UIAction(title: "Original Proportions", image: UIImage(systemName: "rectangle.3.group"),
                     state: layout.style == .justified ? .on : .off) { [weak self] _ in self?.setGridStyle(.justified) },
            UIAction(title: "Square", image: UIImage(systemName: "square.grid.3x3"),
                     state: layout.style == .square ? .on : .off) { [weak self] _ in self?.setGridStyle(.square) },
        ]
        let sizeActions = [0, 32, 64, 128, 256].map { side in
            UIAction(title: side == 0 ? "Show All Sizes" : "Hide Smaller Than \(side) px",
                     state: minimumSide == side ? .on : .off) { [weak self] _ in self?.setMinimumSide(side) }
        }
        let current = Settings.transparencyBackground
        let backgroundActions = TransparencyBackground.allCases.map { background in
            UIAction(title: background.title, state: background == current ? .on : .off) { [weak self] _ in
                Settings.transparencyBackground = background
                self?.menuButton.menu = self?.makeMenu()
            }
        }
        var folderActions: [UIMenuElement] = []
        if let folderURL {
            let isFavorite = FavoriteFoldersStore.shared.contains(folderURL)
            folderActions.append(UIAction(title: isFavorite ? "Remove Folder from Favorites" : "Add Folder to Favorites",
                                          image: UIImage(systemName: isFavorite ? "heart.slash" : "folder.badge.plus")) { _ in
                FavoriteFoldersStore.shared.toggle(folderURL)
            })
        }
        let refresh = UIAction(title: "Refresh", image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in
            // Forget the cached tree so everything is listed again.
            if let url = self?.folderURL { ScanCache.remove(root: url) }
            FolderInfoCache.shared.invalidate()
            self?.reload()
        }
        var sections: [UIMenuElement] = []
        if !isFavoritesView {
            var viewOptions: [UIMenuElement] = [recursive]
            // Only meaningful while folders are listed.
            if !includeSubfolders && (!allFolders.isEmpty || hideEmptyFolders) {
                viewOptions.append(UIAction(title: "Hide Empty Folders", subtitle: "Folders without any images inside",
                                            image: UIImage(systemName: "folder.badge.minus"),
                                            state: hideEmptyFolders ? .on : .off) { [weak self] _ in
                    self?.toggleHideEmptyFolders()
                })
            }
            if imageContext { viewOptions.append(favoritesOnlyAction) }
            sections.append(UIMenu(options: .displayInline, children: viewOptions))
        }
        sections.append(UIMenu(title: "Sort By", image: UIImage(systemName: "arrow.up.arrow.down"), children: [
            UIMenu(options: .displayInline, children: sortActions),
            UIMenu(options: .displayInline, children: directionActions),
        ]))
        if imageContext {
            // The header sits on the first group; nested groups would push it down.
            sections.append(UIMenu(title: "Images", options: .displayInline, children: styleActions))
            sections.append(UIMenu(options: .displayInline, children: [larger, smaller]))
            sections.append(UIMenu(options: .displayInline, children: [
                UIMenu(title: "Image Size", subtitle: minimumSide == 0 ? "All" : "≥ \(minimumSide) px",
                       image: UIImage(systemName: "line.3.horizontal.decrease.circle"), children: sizeActions),
                UIMenu(title: "Transparency", subtitle: current.title,
                       image: UIImage(systemName: "checkerboard.rectangle"), children: backgroundActions),
            ]))
        }
        sections.append(UIMenu(title: folderURL == nil ? "" : "This Folder", options: .displayInline,
                               children: folderActions + [refresh]))
        return UIMenu(children: sections)
    }

    /// Image tools (select, slideshow, grid and image options) only make sense when images can be shown.
    private var showsImageControls: Bool {
        !allImages.isEmpty || includeSubfolders || isFavoritesView || favoritesOnly
    }

    /// Adapts the toolbar buttons, the menu and the search prompt to what the folder contains.
    private func updateContextualControls() {
        let imageContext = showsImageControls
        let items: [UIBarButtonItem] = imageContext ? [menuButton, slideshowButton, selectButton] : [menuButton]
        if items.map(ObjectIdentifier.init) != normalRightItems.map(ObjectIdentifier.init) {
            normalRightItems = items
            if !isSelecting { navigationItem.setRightBarButtonItems(items, animated: false) }
        }
        menuButton.menu = makeMenu()
        let hasFolders = !allFolders.isEmpty
        navigationItem.searchController?.searchBar.placeholder =
            hasFolders && !allImages.isEmpty ? "Filter by name" : hasFolders ? "Filter folders" : "Filter images"
    }

    private func setMinimumSide(_ side: Int) {
        guard side != minimumSide else { return }
        minimumSide = side
        Settings.minimumImageSide = side
        menuButton.menu = makeMenu()
        applyFilter()
    }

    @objc private func toggleFavoritesOnly() {
        guard !isFavoritesView else { return }
        favoritesOnly.toggle()
        menuButton.menu = makeMenu()
        applyFilter()
    }

    @objc private func toggleSubfolders() {
        guard !isFavoritesView else { return }
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

// MARK: - Folder menu

extension BrowserViewController {
    func folderMenu(for url: URL, sourceView: UIView) -> UIMenu {
        let isFavorite = FavoriteFoldersStore.shared.contains(url)
        let favorite = UIAction(title: isFavorite ? "Remove from Favorites" : "Add to Favorites",
                                image: UIImage(systemName: isFavorite ? "heart.slash" : "heart")) { _ in
            FavoriteFoldersStore.shared.toggle(url)
        }
        let share = UIAction(title: "Share", image: UIImage(systemName: "square.and.arrow.up")) { [weak self, weak sourceView] _ in
            let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            activity.popoverPresentationController?.sourceView = sourceView
            self?.present(activity, animated: true)
        }
        let copyName = UIAction(title: "Copy Name", image: UIImage(systemName: "doc.on.doc")) { _ in
            UIPasteboard.general.string = url.lastPathComponent
        }
        return UIMenu(children: [favorite, share, copyName])
    }
}

// MARK: - Selection

extension BrowserViewController: UIDocumentPickerDelegate {
    private func setupSelectionToolbar() {
        selectionLabel.font = .preferredFont(forTextStyle: .headline)
        selectionLabel.textAlignment = .center
        shareSelectionButton = UIBarButtonItem(image: UIImage(systemName: "square.and.arrow.up"), style: .plain,
                                               target: self, action: #selector(shareSelection))
        shareSelectionButton.accessibilityLabel = "Share"
        favoriteSelectionButton = UIBarButtonItem(image: UIImage(systemName: "heart"), style: .plain,
                                                  target: self, action: #selector(toggleFavoriteSelection))
        favoriteSelectionButton.accessibilityLabel = "Favorite"
        folderSelectionButton = UIBarButtonItem(image: UIImage(systemName: "folder.badge.plus"), menu: nil)
        folderSelectionButton.accessibilityLabel = "Copy or Move"
        compareSelectionButton = UIBarButtonItem(image: UIImage(systemName: "square.split.2x1"), style: .plain,
                                                 target: self, action: #selector(compareSelection))
        compareSelectionButton.accessibilityLabel = "Compare"
        toolbarItems = [
            shareSelectionButton,
            .fixedSpace(16),
            compareSelectionButton,
            .flexibleSpace(),
            UIBarButtonItem(customView: selectionLabel),
            .flexibleSpace(),
            favoriteSelectionButton,
            .fixedSpace(16),
            folderSelectionButton,
        ]
    }

    @objc func enterSelection() {
        guard !isSelecting else { return }
        isSelecting = true
        collectionView.allowsMultipleSelection = true
        collectionView.isEditing = true
        navigationItem.hidesBackButton = true
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in self?.exitSelection() }),
            UIBarButtonItem(title: "Select All", primaryAction: UIAction { [weak self] _ in self?.toggleSelectAll() }),
        ]
        navigationController?.setToolbarHidden(false, animated: true)
        updateSelectionUI()
    }

    @objc func exitSelection() {
        guard isSelecting else { return }
        isSelecting = false
        selectedURLs.removeAll()
        for indexPath in collectionView.indexPathsForSelectedItems ?? [] {
            collectionView.deselectItem(at: indexPath, animated: false)
        }
        collectionView.isEditing = false
        collectionView.allowsMultipleSelection = false
        navigationItem.hidesBackButton = false
        navigationItem.rightBarButtonItems = normalRightItems
        navigationController?.setToolbarHidden(true, animated: true)
        updateStatus()
    }

    @objc private func selectAllFromKeyboard() {
        enterSelection()
        if selectedURLs.count != images.count { toggleSelectAll() }
    }

    private func toggleSelectAll() {
        if !images.isEmpty && selectedURLs.count == images.count {
            selectedURLs.removeAll()
            for indexPath in collectionView.indexPathsForSelectedItems ?? [] {
                collectionView.deselectItem(at: indexPath, animated: false)
            }
        } else {
            selectedURLs = Set(images.map(\.url))
            restoreSelection()
        }
        updateSelectionUI()
    }

    /// Re-applies `selectedURLs` after the list was rebuilt, dropping items that are no longer shown.
    private func restoreSelection() {
        guard isSelecting, !selectedURLs.isEmpty else { return }
        var kept = Set<URL>()
        for (index, item) in images.enumerated() where selectedURLs.contains(item.url) {
            kept.insert(item.url)
            collectionView.selectItem(at: IndexPath(item: index, section: Section.images.rawValue), animated: false, scrollPosition: [])
        }
        selectedURLs = kept
        updateSelectionUI()
    }

    // MARK: Swipe to select

    private func imageIndex(at pointInCollectionView: CGPoint) -> Int? {
        guard let indexPath = collectionView.indexPathForItem(at: pointInCollectionView),
              indexPath.section == Section.images.rawValue, indexPath.item < images.count else { return nil }
        return indexPath.item
    }

    @objc private func handleSelectionPan(_ pan: UIPanGestureRecognizer) {
        handleDragSelection(pan)
    }

    @objc private func handleSelectionLongPress(_ press: UILongPressGestureRecognizer) {
        if press.state == .began {
            guard imageIndex(at: press.location(in: collectionView)) != nil else {
                press.state = .cancelled
                return
            }
            if !isSelecting {
                enterSelection()
            }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
        handleDragSelection(press)
    }

    /// Shared by the horizontal swipe (selection mode) and the long-press drag: the first image
    /// decides whether the drag selects or deselects, then the range up to the finger follows it.
    private func handleDragSelection(_ gesture: UIGestureRecognizer) {
        switch gesture.state {
        case .began:
            guard let start = imageIndex(at: gesture.location(in: collectionView)) else { return }
            let selecting = !selectedURLs.contains(images[start].url)
            dragSelection = (start, start, selecting, selectedURLs)
            lastPanLocation = gesture.location(in: view)
            // The finger now selects instead of scrolling; auto-scroll takes over near the edges.
            collectionView.isScrollEnabled = false
            applyDragSelection(to: start, previous: start)
        case .changed:
            lastPanLocation = gesture.location(in: view)
            extendDragSelection()
            updateAutoScroll()
        default:
            dragSelection = nil
            collectionView.isScrollEnabled = true
            stopAutoScroll()
        }
    }

    private func extendDragSelection() {
        guard let drag = dragSelection,
              let index = imageIndex(at: view.convert(lastPanLocation, to: collectionView)),
              index != drag.last else { return }
        applyDragSelection(to: index, previous: drag.last)
    }

    /// Selection = original state, with the range start…index forced on (or off).
    private func applyDragSelection(to index: Int, previous: Int) {
        guard var drag = dragSelection else { return }
        let range = min(drag.start, index)...max(drag.start, index)
        let touched = min(drag.start, index, previous)...max(drag.start, index, previous)
        for item in touched {
            let url = images[item].url
            let shouldSelect = range.contains(item) ? drag.selecting : drag.original.contains(url)
            guard shouldSelect != selectedURLs.contains(url) else { continue }
            let indexPath = IndexPath(item: item, section: Section.images.rawValue)
            if shouldSelect {
                selectedURLs.insert(url)
                collectionView.selectItem(at: indexPath, animated: false, scrollPosition: [])
            } else {
                selectedURLs.remove(url)
                collectionView.deselectItem(at: indexPath, animated: false)
            }
        }
        drag.last = index
        dragSelection = drag
        updateSelectionUI()
    }

    private func updateAutoScroll() {
        let safe = view.safeAreaLayoutGuide.layoutFrame
        let edge: CGFloat = 70
        if lastPanLocation.y < safe.minY + edge {
            autoScrollSpeed = -min(24, (safe.minY + edge - lastPanLocation.y) / 2)
        } else if lastPanLocation.y > safe.maxY - edge {
            autoScrollSpeed = min(24, (lastPanLocation.y - (safe.maxY - edge)) / 2)
        } else {
            autoScrollSpeed = 0
        }
        if autoScrollSpeed == 0 {
            stopAutoScroll()
        } else if autoScrollLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(autoScrollTick))
            link.add(to: .main, forMode: .common)
            autoScrollLink = link
        }
    }

    @objc private func autoScrollTick() {
        let minY = -collectionView.adjustedContentInset.top
        let maxY = max(minY, collectionView.contentSize.height - collectionView.bounds.height + collectionView.adjustedContentInset.bottom)
        collectionView.contentOffset.y = min(max(collectionView.contentOffset.y + autoScrollSpeed, minY), maxY)
        extendDragSelection()
    }

    private func stopAutoScroll() {
        autoScrollLink?.invalidate()
        autoScrollLink = nil
        autoScrollSpeed = 0
    }

    private func selectedURLsInOrder() -> [URL] {
        images.lazy.map(\.url).filter(selectedURLs.contains)
    }

    private func updateSelectionUI() {
        guard isSelecting else { return }
        let count = selectedURLs.count
        selectionLabel.text = count == 0 ? "Select Items" : "\(count.formatted()) Selected"
        selectionLabel.sizeToFit()
        titleView.subtitleLabel.text = count == 0 ? "Tap or drag to select" : "\(count.formatted()) of \(images.count.formatted()) selected"
        let hasSelection = count > 0
        shareSelectionButton.isEnabled = hasSelection
        favoriteSelectionButton.isEnabled = hasSelection
        folderSelectionButton.isEnabled = hasSelection
        compareSelectionButton.isEnabled = count == 2
        let allFavorite = hasSelection && selectedURLs.allSatisfy(FavoritesStore.shared.contains)
        favoriteSelectionButton.image = UIImage(systemName: allFavorite ? "heart.fill" : "heart")
        favoriteSelectionButton.accessibilityLabel = allFavorite ? "Remove from Favorites" : "Add to Favorites"
        folderSelectionButton.menu = makeFolderMenu()
        if let item = navigationItem.rightBarButtonItems?.last {
            item.title = !images.isEmpty && count == images.count ? "Deselect All" : "Select All"
        }
    }

    // MARK: Actions

    @objc private func shareSelection() {
        let urls = selectedURLsInOrder()
        guard !urls.isEmpty else { return }
        let activity = UIActivityViewController(activityItems: urls, applicationActivities: nil)
        activity.popoverPresentationController?.barButtonItem = shareSelectionButton
        present(activity, animated: true)
    }

    /// Exactly two images: open them in the compare view (A = first in grid order).
    @objc private func compareSelection() {
        let urls = selectedURLsInOrder()
        guard urls.count == 2,
              let first = images.first(where: { $0.url == urls[0] }),
              let second = images.first(where: { $0.url == urls[1] }) else { return }
        present(CompareViewController(first: first, second: second), animated: true)
    }

    @objc private func toggleFavoriteSelection() {
        let urls = Array(selectedURLs)
        guard !urls.isEmpty else { return }
        let makeFavorite = !urls.allSatisfy(FavoritesStore.shared.contains)
        FavoritesStore.shared.set(urls, favorite: makeFavorite)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        updateSelectionUI()
    }

    private func makeFolderMenu() -> UIMenu {
        var children: [UIMenuElement] = []
        if folderURL != nil {
            children.append(UIAction(title: "New Folder with Selection…", image: UIImage(systemName: "folder.badge.plus")) { [weak self] _ in
                self?.promptNewFolder()
            })
        }
        children.append(UIAction(title: "Copy to…", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in
            self?.exportSelection(move: false)
        })
        children.append(UIAction(title: "Move to…", image: UIImage(systemName: "folder")) { [weak self] _ in
            self?.exportSelection(move: true)
        })
        return UIMenu(children: children)
    }

    private func promptNewFolder() {
        guard let parent = folderURL else { return }
        let sources = selectedURLsInOrder()
        guard !sources.isEmpty else { return }
        let alert = UIAlertController(title: "New Folder",
                                      message: "\(sources.count.formatted()) image\(sources.count == 1 ? "" : "s") will go into a new folder inside “\(displayName)”.",
                                      preferredStyle: .alert)
        alert.addTextField { field in
            field.text = "New Folder"
            field.clearButtonMode = .whileEditing
            field.autocapitalizationType = .words
        }
        let name = { (alert.textFields?.first?.text ?? "").trimmingCharacters(in: .whitespaces) }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Copy", style: .default) { [weak self] _ in
            self?.transfer(sources, intoNewFolder: name(), in: parent, move: false)
        })
        alert.addAction(UIAlertAction(title: "Move", style: .default) { [weak self] _ in
            self?.transfer(sources, intoNewFolder: name(), in: parent, move: true)
        })
        present(alert, animated: true)
    }

    private func transfer(_ sources: [URL], intoNewFolder rawName: String, in parent: URL, move: Bool) {
        let name = rawName.isEmpty ? "New Folder" : rawName.replacingOccurrences(of: "/", with: "-")
        let progress = UIAlertController(title: move ? "Moving…" : "Copying…",
                                         message: "\(sources.count.formatted()) images", preferredStyle: .alert)
        present(progress, animated: true)
        DispatchQueue.global(qos: .userInitiated).async {
            let fileManager = FileManager.default
            var failures = 0
            var moved: [(URL, URL)] = []
            let folder = Self.uniqueURL(parent.appendingPathComponent(name, isDirectory: true))
            do {
                try fileManager.createDirectory(at: folder, withIntermediateDirectories: false)
                for source in sources {
                    let destination = Self.uniqueURL(folder.appendingPathComponent(source.lastPathComponent))
                    do {
                        if move {
                            try fileManager.moveItem(at: source, to: destination)
                            moved.append((source, destination))
                        } else {
                            try fileManager.copyItem(at: source, to: destination)
                        }
                    } catch {
                        failures += 1
                    }
                }
            } catch {
                failures = sources.count
            }
            DispatchQueue.main.async { [weak self] in
                moved.forEach { FavoritesStore.shared.move(from: $0.0, to: $0.1) }
                progress.dismiss(animated: true) {
                    self?.finishTransfer(failures: failures, total: sources.count, folderName: folder.lastPathComponent, move: move)
                }
            }
        }
    }

    private func finishTransfer(failures: Int, total: Int, folderName: String?, move: Bool) {
        exitSelection()
        FolderInfoCache.shared.invalidate()
        reload()
        guard failures > 0 else { return }
        let alert = UIAlertController(title: "Some Images Weren't \(move ? "Moved" : "Copied")",
                                      message: "\(failures) of \(total) could not be \(move ? "moved" : "copied").",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }

    /// Lets the user pick any destination the Files app can reach.
    private func exportSelection(move: Bool) {
        let sources = selectedURLsInOrder()
        guard !sources.isEmpty else { return }
        pendingExport = (sources, move)
        let picker = UIDocumentPickerViewController(forExporting: sources, asCopy: !move)
        picker.delegate = self
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let export = pendingExport else { return }
        pendingExport = nil
        if export.isMove {
            // Keep favourites attached to the moved files (matched by name).
            let destinations = Dictionary(urls.map { ($0.lastPathComponent, $0) }, uniquingKeysWith: { first, _ in first })
            for source in export.sources {
                if let destination = destinations[source.lastPathComponent] {
                    FavoritesStore.shared.move(from: source, to: destination)
                }
            }
        }
        finishTransfer(failures: 0, total: export.sources.count, folderName: nil, move: export.isMove)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        pendingExport = nil
    }

    private static func uniqueURL(_ url: URL) -> URL {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let parent = url.deletingLastPathComponent()
        var counter = 2
        while true {
            let name = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            let candidate = parent.appendingPathComponent(name)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
            counter += 1
        }
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
            let folder = folders[indexPath.item]
            cell.configure(with: folder)
            cell.menuProvider = { [weak self, weak cell] in
                guard let self, let cell, !self.isSelecting else { return nil }
                return self.folderMenu(for: folder.url, sourceView: cell)
            }
            return cell
        }
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: ThumbnailCell.reuseID, for: indexPath) as! ThumbnailCell
        cell.configure(with: images[indexPath.item], pixelSize: thumbnailPixels(for: indexPath.item))
        return cell
    }
}

extension BrowserViewController: UICollectionViewDataSourcePrefetching {
    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        for indexPath in indexPaths where indexPath.section == Section.images.rawValue && indexPath.item < images.count {
            guard prefetchTokens[indexPath] == nil else { continue }
            let request = ImagePipeline.Request(images[indexPath.item], maxPixel: thumbnailPixels(for: indexPath.item))
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
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        prioritizeVisible()
    }

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        !isSelecting || indexPath.section == Section.images.rawValue
    }

    func collectionView(_ collectionView: UICollectionView, shouldBeginMultipleSelectionInteractionAt indexPath: IndexPath) -> Bool {
        indexPath.section == Section.images.rawValue
    }

    func collectionView(_ collectionView: UICollectionView, didBeginMultipleSelectionInteractionAt indexPath: IndexPath) {
        enterSelection()
    }

    func collectionView(_ collectionView: UICollectionView, didDeselectItemAt indexPath: IndexPath) {
        guard isSelecting, indexPath.section == Section.images.rawValue, indexPath.item < images.count else { return }
        selectedURLs.remove(images[indexPath.item].url)
        updateSelectionUI()
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        if isSelecting {
            if indexPath.section == Section.images.rawValue, indexPath.item < images.count {
                selectedURLs.insert(images[indexPath.item].url)
                updateSelectionUI()
            }
            return
        }
        collectionView.deselectItem(at: indexPath, animated: false)
        switch Section(rawValue: indexPath.section)! {
        case .folders:
            navigationController?.pushViewController(BrowserViewController(folderURL: folders[indexPath.item].url), animated: true)
        case .images:
            openViewer(at: indexPath.item)
        }
    }

}

extension BrowserViewController: UIGestureRecognizerDelegate {
    /// Swipe selection only starts on a mostly horizontal drag, so vertical drags keep scrolling.
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === selectionLongPress {
            return imageIndex(at: selectionLongPress.location(in: collectionView)) != nil
        }
        guard gestureRecognizer === selectionPan else { return true }
        guard isSelecting else { return false }
        let velocity = selectionPan.velocity(in: collectionView)
        return abs(velocity.x) > abs(velocity.y)
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
