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
    /// Holds `emptyLabel` as the grid's background, so the label can be centred beside the sidebar.
    private let emptyView = UIView()

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
    /// Newly read image sizes reshape the grid; while scrolling that happens at most once a second.
    private var pendingMetricsRefilter = false
    private var lastMetricsRefilter: CFAbsoluteTime = 0
    private var lastPrioritize: CFAbsoluteTime = 0
    private var minimumSide = Settings.minimumImageSide
    /// Only images where this colour family is prominent (needs colour analysis).
    private var colorFilter: ColorFamily?
    private var tagFilter: TagColor?
    private var tagSelectionButton: UIBarButtonItem!
    private var searchesText = Settings.searchTextInImages
    /// Background analysis feeding the colour filter and text search, with its progress.
    private var analysisJobs: [AnalysisKind: AnalysisJob] = [:]
    private var analysisProgress: [AnalysisKind: (done: Int, total: Int)] = [:]
    private var analysisRefilterScheduled = false
    private var contentGeneration = 0
    private var prefetchTokens: [IndexPath: LoadToken] = [:]
    private var menuButton: UIBarButtonItem!
    private var normalRightItems: [UIBarButtonItem] = []
    /// Buttons specific to this kind of view (e.g. "Select Copies" for duplicates), shown first.
    private var extraRightItems: [UIBarButtonItem] = []
    private var slideshowButton: UIBarButtonItem!
    /// Floating glass bar: scope (folders / whole tree / favourites) and thumbnail size.
    private let scopeBar = GlassView()
    private let scopeControl = UISegmentedControl(items: ["Folders", "All Images", "Favorites"])
    private let sizeSlider = UISlider()
    private let sizeControls = UIStackView()
    private var fastScroller: FastScroller!
    private var selectButton: UIBarButtonItem!

    // Selection mode
    private(set) var isSelecting = false
    private var selectedURLs = Set<URL>()
    private let selectionLabel = UILabel()
    private var shareSelectionButton: UIBarButtonItem!
    private var favoriteSelectionButton: UIBarButtonItem!
    private var folderSelectionButton: UIBarButtonItem!
    private var compareSelectionButton: UIBarButtonItem!
    private var animateSelectionButton: UIBarButtonItem!
    private var deleteSelectionButton: UIBarButtonItem!
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

    /// A saved smart album: the folder with its saved filters (which don't change the app's defaults).
    convenience init(folderURL: URL, smartAlbum album: SmartAlbum) {
        self.init(folderURL: folderURL, displayName: album.name)
        includeSubfolders = album.includeSubfolders
        minimumSide = album.minimumSide
        favoritesOnly = album.favoritesOnly
        colorFilter = album.colorFamily
        tagFilter = album.tagColor
        query = album.query
    }

    /// Every favourite image across all folders.
    init(favorites: ()) {
        self.folderURL = nil
        self.displayName = "Favorites"
        super.init(nibName: nil, bundle: nil)
    }

    /// A fixed list of images from anywhere (duplicates, similar images, a tag…), optionally in groups.
    init(collection: ImageCollection) {
        self.folderURL = nil
        self.displayName = collection.title
        self.collection = collection
        super.init(nibName: nil, bundle: nil)
    }

    private var collection: ImageCollection?
    private var isFavoritesView: Bool { folderURL == nil && collection == nil }
    /// Favourites or a collection: images from many folders, no folder of its own.
    private var isListView: Bool { folderURL == nil }
    private var favoritesOnly = false
    private var showsOnlyFavorites: Bool { favoritesOnly || isFavoritesView }
    private var needsRefilter = false

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        scanFlag?.cancelled = true
        resolver?.cancel()
        analysisJobs.values.forEach { $0.cancel() }
    }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.background
        navigationItem.largeTitleDisplayMode = .never
        titleView.titleLabel.text = displayName
        navigationItem.titleView = titleView
        title = displayName

        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = Theme.background
        // Inset on every edge: on iPadOS 26 the sidebar floats over the detail column's leading edge.
        collectionView.contentInsetAdjustmentBehavior = .always
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.prefetchDataSource = self
        // Long press selects; while selecting, long-pressing a selected image drags the whole selection out.
        collectionView.dragInteractionEnabled = true
        collectionView.dragDelegate = self
        collectionView.keyboardDismissMode = .onDrag
        collectionView.register(ThumbnailCell.self, forCellWithReuseIdentifier: ThumbnailCell.reuseID)
        collectionView.register(FolderCell.self, forCellWithReuseIdentifier: FolderCell.reuseID)
        collectionView.register(GroupHeaderView.self, forSupplementaryViewOfKind: GalleryLayout.groupHeaderKind,
                                withReuseIdentifier: GroupHeaderView.reuseID)
        collectionView.addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:))))
        view.addSubview(collectionView)
        layout.style = Settings.gridStyle
        layout.targetSize = Self.gridLevels[gridLevel]

        emptyLabel.textColor = .secondaryLabel
        emptyLabel.textAlignment = .center
        emptyLabel.numberOfLines = 0
        emptyLabel.font = .preferredFont(forTextStyle: .title3)
        emptyView.addSubview(emptyLabel)
        observeSidebarChanges { [weak self] in self?.positionEmptyLabel() }

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
        setupScopeBar()
        if collection?.isDuplicates == true {
            extraRightItems = [UIBarButtonItem(title: "Select Copies", primaryAction: UIAction { [weak self] _ in self?.selectCopies() })]
            normalRightItems = extraRightItems + normalRightItems
            navigationItem.rightBarButtonItems = normalRightItems
        }
        if presentingViewController != nil, navigationController?.viewControllers.first === self {
            // Shown on its own (duplicates, similar images): needs a way out.
            navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in
                self?.dismiss(animated: true)
            })
        }
        setupFastScroller()

        NotificationCenter.default.addObserver(self, selector: #selector(favoritesChanged(_:)),
                                               name: FavoritesStore.didChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(tagsChanged),
                                               name: TagStore.didChange, object: nil)
        if !query.isEmpty { search.searchBar.text = query }
        NotificationCenter.default.addObserver(forName: TransparencyBackground.didChange, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            for case let cell as ThumbnailCell in self.collectionView.visibleCells { cell.updateBackground() }
            self.menuButton.menu = self.makeMenu()
        }
        reload()
    }

    /// A small gap from the sidebar while it is on screen; edge to edge when it is hidden.
    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        let sidebarShown = splitViewController.map { !$0.isCollapsed && $0.displayMode != .secondaryOnly } ?? false
        layout.imageInset = sidebarShown ? 16 : 0
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        positionEmptyLabel()
    }

    /// Centred in what the floating sidebar and the bars leave visible, not under the sidebar.
    private func positionEmptyLabel() {
        guard collectionView.backgroundView === emptyView else { return }
        emptyView.layoutIfNeeded()
        let area = view.convert(areaClearOfSidebar, to: emptyView).insetBy(dx: 24, dy: 0)
        emptyLabel.frame = area.width > 0 ? area : emptyView.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        updateBreadcrumbs()
        if needsRefilter {
            needsRefilter = false
            collection?.source != nil ? reload() : applyFilter()
        }
    }

    /// Every folder above this one in the navigation stack becomes a tappable crumb.
    private func updateBreadcrumbs() {
        guard let stack = navigationController?.viewControllers,
              let index = stack.firstIndex(of: self) else { return }
        let ancestors = stack[..<index].compactMap { $0 as? BrowserViewController }.map { ancestor in
            TitleView.Crumb(title: ancestor.displayName) { [weak self] in
                self?.navigationController?.popToViewController(ancestor, animated: true)
            }
        }
        titleView.setPath(ancestors: ancestors)
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

    @objc private func tagsChanged() {
        for case let cell as ThumbnailCell in collectionView.visibleCells { cell.updateFavorite() }
        if isSelecting { updateSelectionUI() }
        guard tagFilter != nil || collection?.source != nil else { return }
        if presentedViewController != nil {
            needsRefilter = true
        } else if collection?.source != nil {
            reload()
        } else {
            applyFilter(keepPosition: true)
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
        ] + (isSelecting ? [
            UIKeyCommand(title: "Done", action: #selector(exitSelection), input: UIKeyCommand.inputEscape),
            UIKeyCommand(title: "Delete", action: #selector(confirmDeleteSelection), input: "\u{8}", modifierFlags: .command),
        ] : [])
    }

    // MARK: Loading

    private func reload() {
        scanFlag?.cancelled = true
        let flag = CancelFlag()
        scanFlag = flag
        let order = Settings.sortOrder
        isScanning = true
        updateStatus()

        if let collection {
            let sourceURLs = collection.source?()
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                // Drop anything deleted or moved since the collection was made.
                let images = sourceURLs.map { urls in
                    urls.compactMap { url -> ImageItem? in
                        guard let values = try? url.resourceValues(forKeys: FolderScanner.keys), values.isDirectory != true else { return nil }
                        return ImageItem(url: url, size: values.fileSize ?? 0, modified: values.contentModificationDate ?? .distantPast)
                    }.sorted(by: order, byPath: true)
                } ?? collection.images.filter { FileManager.default.fileExists(atPath: $0.url.path) }
                    .droppingLoneDuplicates(in: collection)
                DispatchQueue.main.async {
                    guard let self, !flag.cancelled else { return }
                    self.isScanning = false
                    self.setContent(folders: [], images: images)
                }
            }
            return
        }
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
        // Collections keep their own order (e.g. most similar first); live ones are simply re-read.
        if let collection {
            collection.source == nil ? applyFilter() : reload()
            return
        }
        guard !isScanning else { reload(); return }
        let order = Settings.sortOrder
        let fromTree = includeSubfolders && !isListView
        let folders = allFolders
        let images = fromTree ? treeOrder : allImages
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let sortedFolders = folders.sorted(by: SortOrder(key: order.key == .size ? .name : order.key, ascending: order.ascending))
            let sortedImages = fromTree ? Self.ordered(images, by: order) : images.sorted(by: order, byPath: self?.isListView ?? false)
            DispatchQueue.main.async {
                self?.setContent(folders: sortedFolders, images: sortedImages)
            }
        }
    }

    private func setContent(folders: [FolderItem], images: [ImageItem]) {
        allFolders = folders
        allImages = images
        applyFilter()
        // Keep active analyses covering the (possibly new) list once it is complete.
        if !isScanning && !images.isEmpty {
            if colorFilter != nil { startAnalysis(.visual) }
            if searchesText { startAnalysis(.text) }
        }
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
        let isListView = self.isListView
        let collection = self.collection
        // Group by folder only when consecutive images share a folder: tree walks sorted by name.
        let groupRoot: URL? = collection == nil && (includeSubfolders || isFavoritesView) && Settings.sortOrder.key == .name
            ? (folderURL ?? URL(fileURLWithPath: "/")) : nil
        let rootName = displayName
        let emptyFolders = hideEmptyFolders ? knownEmptyFolders() : []
        // The analysis store is only touched (and read from disk) when a filter needs it.
        let colorKeys: Set<String>? = colorFilter.map { ImageAnalysisStore.shared.keys(matching: $0) }
        let textKeys: Set<String> = searchesText && !query.isEmpty ? ImageAnalysisStore.shared.keys(containingText: query) : []
        let tagKeys: Set<String>? = tagFilter.map { TagStore.shared.keys(for: $0) }
        let needsKey = favoriteKeys != nil || colorKeys != nil || tagKeys != nil || !textKeys.isEmpty

        filterQueue.async { [weak self] in
            // A newer request is already queued: skip this one.
            guard latestFilter.withLock({ $0 }) == generation else { return }

            var folders = query.isEmpty ? allFolders : allFolders.filter { $0.name.localizedCaseInsensitiveContains(query) }
            if isListView { folders = [] }
            let foldersBeforeHiding = folders.count
            if !emptyFolders.isEmpty { folders.removeAll { emptyFolders.contains($0.url) } }
            let hiddenEmpty = foldersBeforeHiding - folders.count

            var base: [ImageItem] = []
            base.reserveCapacity(favoriteKeys == nil ? allImages.count : 64)
            for item in allImages {
                let key = needsKey ? FavoritesStore.key(path: item.url.path) : ""
                if let favoriteKeys, !favoriteKeys.contains(key) { continue }
                if let colorKeys, !colorKeys.contains(key) { continue }
                if let tagKeys, !tagKeys.contains(key) { continue }
                // The name, or (when enabled) text found inside the image.
                if !query.isEmpty && !item.name.localizedCaseInsensitiveContains(query) && !textKeys.contains(key) { continue }
                base.append(item)
            }

            let allMetrics = ImageMetricsStore.shared.metrics(for: base.map(\.url))
            var images: [ImageItem] = []
            var sourceIndices: [Int] = []
            var ratios: [CGFloat] = []
            var hidden = 0
            images.reserveCapacity(base.count)
            ratios.reserveCapacity(base.count)
            sourceIndices.reserveCapacity(base.count)
            for (index, item) in base.enumerated() {
                let metrics = allMetrics[index]
                // Unknown sizes stay visible until the resolver has read them.
                if minimumSide > 0, let metrics, metrics.maxSide > 0, metrics.maxSide < minimumSide {
                    hidden += 1
                    continue
                }
                images.append(item)
                sourceIndices.append(index)
                ratios.append(metrics?.ratio ?? ImageMetricsStore.placeholderRatio)
            }
            let groups = collection.map { Self.collectionGroups(for: images, in: $0) }
                ?? groupRoot.map { Self.folderGroups(for: images, root: $0, rootName: rootName) } ?? []

            DispatchQueue.main.async {
                guard let self, self.filterGeneration == generation else { return }
                self.hiddenEmptyFolderCount = hiddenEmpty
                self.layout.groups = groups
                self.applyFiltered(folders: folders, base: base, images: images, sourceIndices: sourceIndices,
                                   ratios: ratios, hidden: hidden, keepPosition: keepPosition)
                if restartResolver { self.startResolverIfNeeded() }
            }
        }
    }

    /// One group per run of images that share a collection group (e.g. one set of duplicates).
    private static func collectionGroups(for images: [ImageItem], in collection: ImageCollection) -> [GalleryLayout.Group] {
        guard !collection.groupOf.isEmpty else { return [] }
        var groups: [GalleryLayout.Group] = []
        var index = 0
        while index < images.count {
            let id = collection.groupOf[images[index].url]
            var end = index + 1
            while end < images.count, collection.groupOf[images[end].url] == id { end += 1 }
            let count = end - index
            let bytes = images[index..<end].reduce(0) { $0 + $1.size }
            groups.append(GalleryLayout.Group(
                start: index,
                title: id.flatMap { collection.groupTitles[$0] } ?? "Other",
                subtitle: "\(count.formatted()) image\(count == 1 ? "" : "s") · \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))"
                    + (collection.isDuplicates ? " · the first one is the original" : "")))
            index = end
        }
        return groups
    }

    /// One group per run of images from the same folder, titled with the folder's name and path.
    private static func folderGroups(for images: [ImageItem], root: URL, rootName: String) -> [GalleryLayout.Group] {
        var groups: [GalleryLayout.Group] = []
        let rootPath = root.standardizedFileURL.path
        var index = 0
        while index < images.count {
            let folder = images[index].url.deletingLastPathComponent()
            let folderPath = folder.standardizedFileURL.path
            var end = index + 1
            while end < images.count, images[end].url.deletingLastPathComponent().standardizedFileURL.path == folderPath {
                end += 1
            }
            let count = end - index
            let isRoot = folderPath == rootPath
            var relative = folderPath.hasPrefix(rootPath + "/") ? String(folderPath.dropFirst(rootPath.count + 1)) : folderPath
            if let slash = relative.lastIndex(of: "/") { relative = String(relative[..<slash]) } else { relative = "" }
            let location = isRoot ? "" : (relative.isEmpty ? rootName : rootName + " / " + relative.replacingOccurrences(of: "/", with: " / "))
            let countText = "\(count.formatted()) image\(count == 1 ? "" : "s")"
            groups.append(GalleryLayout.Group(start: index,
                                              title: isRoot ? rootName : folder.lastPathComponent,
                                              subtitle: location.isEmpty ? countText : location + " · " + countText))
            index = end
        }
        // A single group adds nothing.
        return groups.count > 1 ? groups : []
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
                cache.info(for: folder.url, modified: folder.modified) { [weak self] info in
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
            self.metricsArrived()
        }
        self.resolver = resolver
        prioritizeVisible()
        resolver.start()
    }

    /// Each batch of sizes relayouts the whole grid; during a scroll, batches are merged so the
    /// grid doesn't stutter, and the last one is applied as soon as the scroll stops.
    private func metricsArrived() {
        let now = CFAbsoluteTimeGetCurrent()
        if collectionView.isDragging || collectionView.isDecelerating, now - lastMetricsRefilter < 1 {
            pendingMetricsRefilter = true
            return
        }
        pendingMetricsRefilter = false
        lastMetricsRefilter = now
        applyFilter(keepPosition: true, restartResolver: false)
    }

    private func applyPendingMetrics() {
        guard pendingMetricsRefilter else { return }
        pendingMetricsRefilter = false
        lastMetricsRefilter = CFAbsoluteTimeGetCurrent()
        applyFilter(keepPosition: true, restartResolver: false)
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
        if let colorFilter { parts.insert(colorFilter.title, at: 0) }
        if let tagFilter { parts.insert("\(tagFilter.title) tag", at: 0) }
        for (kind, label) in [(AnalysisKind.visual, "analyzing colors"), (.text, "reading text")] {
            if let progress = analysisProgress[kind], progress.done < progress.total {
                parts.append("\(label) \(progress.done.formatted()) / \(progress.total.formatted())")
            }
        }
        if isRevalidating {
            parts.append("checking for changes…")
        } else if isScanning {
            parts.append(includeSubfolders ? "scanning…" : "loading…")
        }
        if includeSubfolders && !isListView { parts.insert("All subfolders", at: 0) }
        if favoritesOnly { parts.insert("Favorites", at: 0) }
        titleView.subtitleLabel.text = parts.joined(separator: " · ")

        if !isScanning && folders.isEmpty && images.isEmpty {
            if !query.isEmpty {
                emptyLabel.text = "No matches for “\(query)”"
            } else if showsOnlyFavorites && isFavoritesView && FavoritesStore.shared.count > 0 {
                // Favourites exist, but in folders removed from the sidebar or on a disconnected drive.
                emptyLabel.text = "Your favorites can't be reached\nThey're in folders that are no longer in the sidebar or on a drive that isn't connected. Open their folder again to see them."
            } else if showsOnlyFavorites {
                emptyLabel.text = "No favorites yet\nTap ♥︎ in the viewer, press F, or long-press a thumbnail."
            } else if collection?.isDuplicates == true {
                emptyLabel.text = "No duplicates left\nEvery set is down to its original."
            } else {
                emptyLabel.text = "No images here"
            }
            collectionView.backgroundView = emptyView
            positionEmptyLabel()
        } else {
            collectionView.backgroundView = nil
        }
        if isSelecting { updateSelectionUI() }
        updateContextualControls()
    }

    // MARK: Layout

    private func setGridLevel(_ level: Int, fromSlider: Bool = false) {
        let clamped = min(max(level, 0), Self.gridLevels.count - 1)
        guard clamped != gridLevel else { return }
        gridLevel = clamped
        Settings.gridLevel = clamped
        // Pinch, keyboard and menu change the size too: keep the slider in step
        // (never while it is being dragged, or it would fight the finger).
        if !fromSlider { sizeSlider.setValue(Float(clamped), animated: true) }
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

    // MARK: Fast scroller

    private func setupFastScroller() {
        fastScroller = FastScroller(scrollView: collectionView)
        fastScroller.labelProvider = { [weak self] y in
            guard let self, let index = self.layout.groupIndex(atY: y), self.layout.groups.indices.contains(index) else { return nil }
            return self.layout.groups[index].title
        }
        view.addSubview(fastScroller)
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            fastScroller.topAnchor.constraint(equalTo: guide.topAnchor, constant: 12),
            fastScroller.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -92),
            fastScroller.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            fastScroller.widthAnchor.constraint(equalToConstant: 360),
        ])
        // The floating scope bar stays above the scroller.
        view.bringSubviewToFront(scopeBar)
    }

    // MARK: Scope bar

    private func setupScopeBar() {
        scopeControl.addTarget(self, action: #selector(scopeChanged), for: .valueChanged)
        scopeControl.accessibilityLabel = "Show"

        sizeSlider.minimumValue = 0
        sizeSlider.maximumValue = Float(Self.gridLevels.count - 1)
        sizeSlider.value = Float(gridLevel)
        sizeSlider.accessibilityLabel = "Thumbnail size"
        sizeSlider.addTarget(self, action: #selector(sizeSliderChanged), for: .valueChanged)
        sizeSlider.addTarget(self, action: #selector(sizeSliderReleased), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        sizeSlider.widthAnchor.constraint(equalToConstant: 160).isActive = true
        if #available(iOS 26.0, *) {
            // One tick per size: the thumb snaps to real steps, so every position changes the grid.
            sizeSlider.trackConfiguration = .init(allowsTickValuesOnly: true, numberOfTicks: Self.gridLevels.count)
        }
        let small = UIImageView(image: UIImage(systemName: "square.grid.3x3", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13)))
        let large = UIImageView(image: UIImage(systemName: "square.grid.2x2", withConfiguration: UIImage.SymbolConfiguration(pointSize: 16)))
        for icon in [small, large] {
            icon.tintColor = .secondaryLabel
            icon.setContentHuggingPriority(.required, for: .horizontal)
        }
        sizeControls.addArrangedSubview(small)
        sizeControls.addArrangedSubview(sizeSlider)
        sizeControls.addArrangedSubview(large)
        sizeControls.spacing = 8
        sizeControls.alignment = .center

        let stack = UIStackView(arrangedSubviews: [scopeControl, sizeControls])
        stack.spacing = 16
        stack.alignment = .center
        scopeBar.embed(stack, insets: NSDirectionalEdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 18))
        view.addSubview(scopeBar)
        NSLayoutConstraint.activate([
            scopeBar.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            scopeBar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
            scopeBar.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            scopeBar.heightAnchor.constraint(greaterThanOrEqualToConstant: 52),
        ])
        // Let the last rows scroll clear of the floating bar.
        collectionView.contentInset.bottom = 92
        collectionView.verticalScrollIndicatorInsets.bottom = 92
    }

    private func updateScopeBar(imageContext: Bool) {
        scopeControl.isHidden = isListView
        scopeControl.selectedSegmentIndex = favoritesOnly ? 2 : includeSubfolders ? 1 : 0
        sizeControls.isHidden = !imageContext
        if !sizeSlider.isTracking { sizeSlider.value = Float(gridLevel) }
        scopeBar.isHidden = isSelecting || (isListView && !imageContext)
    }

    @objc private func scopeChanged() {
        switch scopeControl.selectedSegmentIndex {
        case 0: setScope(subfolders: false, favorites: false)
        case 1: setScope(subfolders: true, favorites: false)
        default: setScope(subfolders: true, favorites: true)
        }
    }

    /// Favourites look through the whole tree, so they turn on subfolders too.
    private func setScope(subfolders: Bool, favorites: Bool) {
        favoritesOnly = favorites
        if subfolders != includeSubfolders {
            includeSubfolders = subfolders
            Settings.includeSubfolders = subfolders
            setContent(folders: [], images: [])
            collectionView.setContentOffset(CGPoint(x: 0, y: -collectionView.adjustedContentInset.top), animated: false)
            reload()
        } else {
            applyFilter()
        }
        menuButton.menu = makeMenu()
    }

    @objc private func sizeSliderChanged() {
        setGridLevel(Int(sizeSlider.value.rounded()), fromSlider: true)
    }

    /// Settles the thumb on the step it is showing.
    @objc private func sizeSliderReleased() {
        sizeSlider.setValue(Float(gridLevel), animated: true)
    }

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
        let larger = UIAction(title: "Larger Thumbnails", image: UIImage(systemName: "plus.magnifyingglass"),
                              attributes: gridLevel == Self.gridLevels.count - 1 ? .disabled : []) { [weak self] _ in self?.zoomIn() }
        let smaller = UIAction(title: "Smaller Thumbnails", image: UIImage(systemName: "minus.magnifyingglass"),
                               attributes: gridLevel == 0 ? .disabled : []) { [weak self] _ in self?.zoomOut() }
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
        let colorActions: [UIMenuElement] = [UIAction(title: "Any Color", state: colorFilter == nil ? .on : .off) { [weak self] _ in
            self?.setColorFilter(nil)
        }] + ColorFamily.allCases.map { family in
            UIAction(title: family.title,
                     image: UIImage(systemName: "circle.fill")?.withTintColor(family.swatch, renderingMode: .alwaysOriginal),
                     state: colorFilter == family ? .on : .off) { [weak self] _ in self?.setColorFilter(family) }
        }
        let tagActions: [UIMenuElement] = [UIAction(title: "Any Tag", state: tagFilter == nil ? .on : .off) { [weak self] _ in
            self?.setTagFilter(nil)
        }] + TagColor.allCases.map { tag in
            UIAction(title: tag.title, image: tag.dot, state: tagFilter == tag ? .on : .off) { [weak self] _ in self?.setTagFilter(tag) }
        }
        let textSearch = UIAction(title: "Search Text in Images", subtitle: "Slow the first time",
                                  image: UIImage(systemName: "text.viewfinder"), state: searchesText ? .on : .off) { [weak self] _ in
            self?.toggleTextSearch()
        }
        var folderActions: [UIMenuElement] = []
        if let folderURL, !imageContext {
            // Only folders here: duplicates can still be searched for across everything inside.
            folderActions.append(UIAction(title: "Find Duplicates in Subfolders", subtitle: "Every image inside “\(displayName)”",
                                          image: UIImage(systemName: "square.on.square.badge.person.crop")) { [weak self] _ in
                self?.findDuplicatesInTree(folderURL)
            })
        }
        if folderURL != nil {
            folderActions.append(UIAction(title: "Save as Smart Album…", subtitle: "Keeps these filters in the sidebar",
                                          image: UIImage(systemName: "gearshape.2")) { [weak self] _ in
                self?.promptSmartAlbum()
            })
        }
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
        if !isListView {
            var viewOptions: [UIMenuElement] = []
            // Only meaningful while folders are listed.
            if !includeSubfolders && (!allFolders.isEmpty || hideEmptyFolders) {
                viewOptions.append(UIAction(title: "Hide Empty Folders", subtitle: "Folders without any images inside",
                                            image: UIImage(systemName: "folder.badge.minus"),
                                            state: hideEmptyFolders ? .on : .off) { [weak self] _ in
                    self?.toggleHideEmptyFolders()
                })
            }
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
            // Filters and image analysis live together in one submenu to keep the menu short.
            let active = [colorFilter?.title, tagFilter.map { "\($0.title) tag" }, searchesText ? "Text" : nil].compactMap { $0 }
            sections.append(UIMenu(options: .displayInline, children: [
                UIMenu(title: "Image Size", subtitle: minimumSide == 0 ? "All" : "≥ \(minimumSide) px",
                       image: UIImage(systemName: "line.3.horizontal.decrease.circle"), children: sizeActions),
                UIMenu(title: "Transparency", subtitle: current.title,
                       image: UIImage(systemName: "checkerboard.rectangle"), children: backgroundActions),
                UIMenu(title: "Find & Filter", subtitle: active.isEmpty ? "Color, tags, text, duplicates" : active.joined(separator: " · "),
                       image: UIImage(systemName: "sparkle.magnifyingglass"), children: [
                    UIMenu(options: .displayInline, children: [
                        UIMenu(title: "Color", subtitle: colorFilter?.title ?? "Any",
                               image: UIImage(systemName: "paintpalette"), children: colorActions),
                        UIMenu(title: "Tag", subtitle: tagFilter?.title ?? "Any",
                               image: UIImage(systemName: "tag"), children: tagActions),
                        textSearch,
                    ]),
                    duplicatesMenu(),
                ]),
            ]))
        }
        sections.append(UIMenu(title: folderURL == nil ? "" : "This Folder", options: .displayInline,
                               children: folderActions + (collection == nil ? [refresh] : [])))
        return UIMenu(children: sections)
    }

    /// Image tools (select, slideshow, grid and image options) only make sense when images can be shown.
    private var showsImageControls: Bool {
        !allImages.isEmpty || includeSubfolders || isListView || favoritesOnly
    }

    /// Adapts the toolbar buttons, the menu and the search prompt to what the folder contains.
    private func updateContextualControls() {
        let imageContext = showsImageControls
        updateScopeBar(imageContext: imageContext)
        let items: [UIBarButtonItem] = extraRightItems + (imageContext ? [menuButton, slideshowButton, selectButton] : [menuButton])
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

    // MARK: Analysis

    /// Where to look, spelled out: the images shown here, or this folder with all its subfolders.
    private func duplicatesMenu() -> UIMenuElement {
        let here = UIAction(title: includeSubfolders || isListView ? "Among These Images" : "In This Folder Only",
                            subtitle: "The \(images.count.formatted()) images shown here",
                            image: UIImage(systemName: "square.on.square")) { [weak self] _ in self?.findDuplicates() }
        guard let folderURL, !includeSubfolders else {
            return UIMenu(title: "Find Duplicates", image: UIImage(systemName: "square.on.square.badge.person.crop"), children: [here])
        }
        let tree = UIAction(title: "In This Folder and Subfolders", subtitle: "Every image inside “\(displayName)”",
                            image: UIImage(systemName: "folder.badge.gearshape")) { [weak self] _ in
            self?.findDuplicatesInTree(folderURL)
        }
        return UIMenu(title: "Find Duplicates", image: UIImage(systemName: "square.on.square.badge.person.crop"), children: [here, tree])
    }

    func findDuplicatesInTree(_ root: URL) {
        let alert = UIAlertController(title: "Finding Duplicates", message: "Listing images…", preferredStyle: .alert)
        var cancelled = false
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in cancelled = true })
        present(alert, animated: true)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var items: [ImageItem] = []
            FolderScanner.scanRecursively(root, isCancelled: { cancelled }) { items += $0 }
            DispatchQueue.main.async {
                guard let self, !cancelled else { return }
                alert.dismiss(animated: true) { self.findDuplicates(in: items) }
            }
        }
    }

    /// Selects every image except the first (the original) of each duplicate set, ready to delete.
    private func selectCopies() {
        guard let collection, collection.isDuplicates else { return }
        enterSelection()
        var seen = Set<Int>()
        var copies = Set<URL>()
        for item in images {
            guard let group = collection.groupOf[item.url] else { continue }
            if !seen.insert(group).inserted { copies.insert(item.url) }
        }
        for indexPath in collectionView.indexPathsForSelectedItems ?? [] { collectionView.deselectItem(at: indexPath, animated: false) }
        selectedURLs = copies
        restoreSelection()
        updateSelectionUI()
    }

    private func findDuplicates() { findDuplicates(in: images) }

    private func findDuplicates(in items: [ImageItem]) {
        guard items.count > 1 else { return }
        runAnalysis(.visual, on: items, title: "Finding Duplicates") { [weak self] in
            let signatures = AnalysisFlows.signatures(of: items)
            DispatchQueue.global(qos: .userInitiated).async {
                let collection = AnalysisFlows.duplicates(in: items, signatures: signatures)
                DispatchQueue.main.async {
                    guard let self else { return }
                    if let collection {
                        self.presentCollection(collection)
                    } else {
                        self.showMessage("No Duplicates", "None of these \(items.count.formatted()) images look the same.")
                    }
                }
            }
        }
    }

    private func setTagFilter(_ tag: TagColor?) {
        guard tag != tagFilter else { return }
        tagFilter = tag
        menuButton.menu = makeMenu()
        applyFilter()
    }

    private func promptSmartAlbum() {
        guard let folderURL else { return }
        let alert = UIAlertController(title: "New Smart Album",
                                      message: "Saves this folder with its current filters as a shortcut in the sidebar.", preferredStyle: .alert)
        // Suggest a name that says what is filtered, e.g. "Fotos · Green · boss".
        let hints = [colorFilter?.title, tagFilter.map { "\($0.title) tag" }, query.isEmpty ? nil : query].compactMap { $0 }
        let suggestion = ([displayName] + hints).joined(separator: " · ")
        alert.addTextField { field in
            field.placeholder = "Name"
            field.text = suggestion
            field.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self, weak alert] _ in
            guard let self else { return }
            let name = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespaces) ?? ""
            let album = SmartAlbum(
                id: UUID(), name: name.isEmpty ? self.displayName : name, path: FavoritesStore.key(folderURL),
                bookmark: try? folderURL.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil),
                includeSubfolders: self.includeSubfolders, query: self.query, minimumSide: self.minimumSide,
                favoritesOnly: self.favoritesOnly, color: self.colorFilter?.rawValue, tag: self.tagFilter?.rawValue)
            SmartAlbumStore.shared.add(album)
        })
        present(alert, animated: true)
    }

    private func setColorFilter(_ family: ColorFamily?) {
        guard family != colorFilter else { return }
        colorFilter = family
        menuButton.menu = makeMenu()
        if family != nil { startAnalysis(.visual) }
        applyFilter()
    }

    private func toggleTextSearch() {
        searchesText.toggle()
        Settings.searchTextInImages = searchesText
        menuButton.menu = makeMenu()
        if searchesText {
            startAnalysis(.text)
        } else {
            analysisJobs.removeValue(forKey: .text)?.cancel()
            analysisProgress[.text] = nil
            updateStatus()
        }
        applyFilter()
    }

    /// Analyses this view's images that aren't known yet, refreshing the filter as results arrive.
    private func startAnalysis(_ kind: AnalysisKind) {
        analysisJobs[kind]?.cancel()
        let job = AnalysisJob(kind: kind)
        job.onProgress = { [weak self] done, total in
            self?.analysisProgress[kind] = (done, total)
            self?.updateStatus()
            self?.scheduleAnalysisRefilter()
        }
        job.onFinish = { [weak self] in
            self?.analysisProgress[kind] = nil
            self?.analysisJobs[kind] = nil
            self?.updateStatus()
            self?.applyFilter(keepPosition: true)
        }
        analysisJobs[kind] = job
        job.start(allImages)
    }

    /// Results trickle in: refilter at most every couple of seconds.
    private func scheduleAnalysisRefilter() {
        guard !analysisRefilterScheduled else { return }
        analysisRefilterScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.analysisRefilterScheduled = false
            if self.colorFilter != nil || (self.searchesText && !self.query.isEmpty) {
                self.applyFilter(keepPosition: true)
            }
        }
    }

    @objc private func toggleFavoritesOnly() {
        guard !isListView else { return }
        favoritesOnly.toggle()
        menuButton.menu = makeMenu()
        applyFilter()
    }

    @objc private func toggleSubfolders() {
        guard !isListView else { return }
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
        let share = UIAction(title: "Share", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
            guard let self else { return }
            ShareSheet.present([url], from: self)
        }
        let copyName = UIAction(title: "Copy Name", image: UIImage(systemName: "doc.on.doc")) { _ in
            UIPasteboard.general.string = url.lastPathComponent
        }
        let animate = UIAction(title: "Play as Animation", image: UIImage(systemName: "film.stack")) { [weak self] _ in
            self?.playFolderAsAnimation(url)
        }
        let duplicates = UIAction(title: "Find Duplicates Inside", image: UIImage(systemName: "square.on.square.badge.person.crop")) { [weak self] _ in
            self?.findDuplicatesInTree(url)
        }
        var extras: [UIMenuElement] = [animate, duplicates]
        if UIApplication.shared.supportsMultipleScenes {
            extras.insert(UIAction(title: "Open in New Window", image: UIImage(systemName: "macwindow.badge.plus")) { _ in
                WindowOpener.open(url)
            }, at: 0)
        }
        return UIMenu(children: [favorite, share, copyName, UIMenu(options: .displayInline, children: extras)])
    }

    /// The folder's own images, in name order, as animation frames.
    func playFolderAsAnimation(_ url: URL) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let frames = FolderScanner.list(url).images.sorted(by: SortOrder(key: .name, ascending: true))
            DispatchQueue.main.async {
                guard let self else { return }
                guard frames.count > 1 else {
                    let alert = UIAlertController(title: "Nothing to Animate",
                                                  message: "This folder needs at least two images of its own.", preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "OK", style: .default))
                    self.present(alert, animated: true)
                    return
                }
                self.present(FlipbookViewController(frames: frames), animated: true)
            }
        }
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
        folderSelectionButton.accessibilityLabel = "Copy, Move or Add to Board"
        deleteSelectionButton = UIBarButtonItem(image: UIImage(systemName: "trash"), style: .plain,
                                                target: self, action: #selector(confirmDeleteSelection))
        deleteSelectionButton.tintColor = .systemRed
        deleteSelectionButton.accessibilityLabel = "Delete"
        compareSelectionButton = UIBarButtonItem(image: UIImage(systemName: "square.split.2x1"), style: .plain,
                                                 target: self, action: #selector(compareSelection))
        compareSelectionButton.accessibilityLabel = "Compare"
        animateSelectionButton = UIBarButtonItem(image: UIImage(systemName: "film.stack"), style: .plain,
                                                 target: self, action: #selector(animateSelection))
        animateSelectionButton.accessibilityLabel = "Play as Animation"
        tagSelectionButton = UIBarButtonItem(image: UIImage(systemName: "tag"), menu: nil)
        tagSelectionButton.accessibilityLabel = "Tags"
        toolbarItems = [
            shareSelectionButton,
            .fixedSpace(16),
            compareSelectionButton,
            .fixedSpace(16),
            animateSelectionButton,
            .flexibleSpace(),
            UIBarButtonItem(customView: selectionLabel),
            .flexibleSpace(),
            favoriteSelectionButton,
            .fixedSpace(16),
            tagSelectionButton,
            .fixedSpace(16),
            folderSelectionButton,
            .fixedSpace(16),
            deleteSelectionButton,
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
        scopeBar.isHidden = true
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
            // Haptics only exist on iPhone; on iPad the bounce is the confirmation.
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            if let indexPath = collectionView.indexPathForItem(at: press.location(in: collectionView)),
               let cell = collectionView.cellForItem(at: indexPath) as? ThumbnailCell {
                cell.pulse()
            }
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
        deleteSelectionButton.isEnabled = hasSelection
        compareSelectionButton.isEnabled = count == 2
        animateSelectionButton.isEnabled = count > 1
        tagSelectionButton.isEnabled = hasSelection
        tagSelectionButton.menu = makeTagMenu(for: Array(selectedURLs))
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
        ShareSheet.present(urls, preview: images.first { selectedURLs.contains($0.url) }, from: self)
    }

    /// Exactly two images: open them in the compare view (A = first in grid order).
    @objc private func compareSelection() {
        let urls = selectedURLsInOrder()
        guard urls.count == 2,
              let first = images.first(where: { $0.url == urls[0] }),
              let second = images.first(where: { $0.url == urls[1] }) else { return }
        present(CompareViewController(first: first, second: second), animated: true)
    }

    /// The selected images, in grid order, as animation frames.
    @objc private func animateSelection() {
        let frames = images.filter { selectedURLs.contains($0.url) }
        guard frames.count > 1 else { return }
        present(FlipbookViewController(frames: frames), animated: true)
    }

    @objc private func toggleFavoriteSelection() {
        let urls = Array(selectedURLs)
        guard !urls.isEmpty else { return }
        let makeFavorite = !urls.allSatisfy(FavoritesStore.shared.contains)
        FavoritesStore.shared.set(urls, favorite: makeFavorite)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        updateSelectionUI()
    }

    /// Toggles each tag on the images: on for all if any lacks it, off if they all have it.
    func makeTagMenu(for urls: [URL]) -> UIMenu {
        let store = TagStore.shared
        return UIMenu(title: "Tags", children: TagColor.allCases.map { tag in
            let all = !urls.isEmpty && urls.allSatisfy { store.has(tag, $0) }
            return UIAction(title: tag.title, image: tag.dot, state: all ? .on : .off) { _ in
                store.set(tag, on: urls, !all)
            }
        })
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
        children.append(BoardPrompt.menu(from: self, urls: { [weak self] in self?.selectedURLsInOrder() ?? [] }) { [weak self] board in
            self?.showMessage("Added to “\(board.name)”", "Open the board from the sidebar.")
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

    // MARK: Delete

    @objc private func confirmDeleteSelection() {
        let urls = selectedURLsInOrder()
        guard isSelecting, !urls.isEmpty else { return }
        let count = urls.count
        let noun = count == 1 ? "Image" : "\(count.formatted()) Images"
        let keepsOriginals = collection?.isDuplicates == true && !urls.contains { url in
            // Every set still keeps at least one image: its first one isn't selected.
            images.first { collection?.groupOf[$0.url] == collection?.groupOf[url] }?.url == url
        }
        let alert = UIAlertController(
            title: "Delete \(noun)?",
            message: (keepsOriginals ? "The original of each set stays. " : "")
                + "They will be moved to Recently Deleted in the Files app when the location supports it. "
                + "Otherwise they are deleted permanently and can't be recovered.",
            preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "Delete \(noun)", style: .destructive) { [weak self] _ in
            self?.delete(urls)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.popoverPresentationController?.barButtonItem = deleteSelectionButton
        present(alert, animated: true)
    }

    private func delete(_ urls: [URL]) {
        DispatchQueue.global(qos: .userInitiated).async {
            let fileManager = FileManager.default
            var deleted: [URL] = []
            var failures = 0
            for url in urls {
                do {
                    // Prefer the trash so the deletion can be undone from the Files app.
                    try fileManager.trashItem(at: url, resultingItemURL: nil)
                    deleted.append(url)
                } catch {
                    do {
                        try fileManager.removeItem(at: url)
                        deleted.append(url)
                    } catch {
                        failures += 1
                    }
                }
            }
            DispatchQueue.main.async { [weak self] in
                if !deleted.isEmpty { FavoritesStore.shared.set(deleted, favorite: false) }
                self?.exitSelection()
                FolderInfoCache.shared.invalidate()
                self?.reload()
                guard failures > 0 else { return }
                let alert = UIAlertController(title: "Some Images Weren't Deleted",
                                              message: "\(failures) of \(urls.count) could not be deleted.",
                                              preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                self?.present(alert, animated: true)
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
    func collectionView(_ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String,
                        at indexPath: IndexPath) -> UICollectionReusableView {
        let header = collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: GroupHeaderView.reuseID,
                                                                     for: indexPath) as! GroupHeaderView
        if layout.groups.indices.contains(indexPath.item) {
            let group = layout.groups[indexPath.item]
            header.configure(title: group.title, subtitle: group.subtitle)
        }
        return header
    }

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
        fastScroller?.scrollViewDidScroll()
        // Telling the resolver what is on screen ~10 times a second is plenty.
        let now = CFAbsoluteTimeGetCurrent()
        if resolver != nil, now - lastPrioritize > 0.1 {
            lastPrioritize = now
            prioritizeVisible()
        }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { applyPendingMetrics() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        applyPendingMetrics()
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
            guard let index = imageIndex(at: selectionLongPress.location(in: collectionView)) else { return false }
            // A selected image under the finger: leave the long press to dragging the selection out.
            return !(isSelecting && selectedURLs.contains(images[index].url))
        }
        guard gestureRecognizer === selectionPan else { return true }
        guard isSelecting else { return false }
        let velocity = selectionPan.velocity(in: collectionView)
        return abs(velocity.x) > abs(velocity.y)
    }
}

extension BrowserViewController: UICollectionViewDragDelegate {
    /// Drags the selected images (as files) to other apps, Files or another window.
    func collectionView(_ collectionView: UICollectionView, itemsForBeginning session: UIDragSession,
                        at indexPath: IndexPath) -> [UIDragItem] {
        guard isSelecting, dragSelection == nil, indexPath.section == Section.images.rawValue,
              indexPath.item < images.count, selectedURLs.contains(images[indexPath.item].url) else { return [] }
        let touched = images[indexPath.item]
        // The touched image first (it is the one under the finger), then the rest in grid order.
        let others = images.lazy.filter { $0.url != touched.url && self.selectedURLs.contains($0.url) }.prefix(499)
        return ([touched] + others).map(Self.dragItem)
    }

    func collectionView(_ collectionView: UICollectionView, dragPreviewParametersForItemAt indexPath: IndexPath) -> UIDragPreviewParameters? {
        let parameters = UIDragPreviewParameters()
        if let cell = collectionView.cellForItem(at: indexPath) {
            parameters.visiblePath = UIBezierPath(roundedRect: cell.bounds, cornerRadius: 8)
        }
        return parameters
    }

    static func dragItem(for item: ImageItem) -> UIDragItem {
        let provider = NSItemProvider(contentsOf: item.url) ?? NSItemProvider()
        provider.suggestedName = item.url.deletingPathExtension().lastPathComponent
        let dragItem = UIDragItem(itemProvider: provider)
        dragItem.localObject = item.url
        return dragItem
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

private extension Array where Element == ImageItem {
    /// In a duplicates collection, a set reduced to one image is no longer a duplicate.
    func droppingLoneDuplicates(in collection: ImageCollection) -> [ImageItem] {
        guard collection.isDuplicates else { return self }
        var counts: [Int: Int] = [:]
        for item in self { if let group = collection.groupOf[item.url] { counts[group, default: 0] += 1 } }
        return filter { item in collection.groupOf[item.url].map { (counts[$0] ?? 0) > 1 } ?? false }
    }
}
