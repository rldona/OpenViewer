import UIKit
import UniformTypeIdentifiers

/// A reference board: an endless canvas where images from any folder are placed, moved, resized
/// and rotated freely. Drag empty space to pan, pinch empty space to zoom; drag, pinch or twist an
/// image to arrange it. Saved as you go and exportable as one image.
final class BoardViewController: UIViewController, UIScrollViewDelegate {
    private var board: Board
    private let scrollView = UIScrollView()
    private let canvas = UIView()
    private var itemViews: [UUID: BoardItemView] = [:]
    private var saveScheduled = false
    private let emptyLabel = UILabel()

    init(board: Board) {
        self.board = board
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { ScopedAccess.endAll(owner: self) }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = board.name
        view.backgroundColor = Theme.background
        navigationItem.largeTitleDisplayMode = .never

        scrollView.frame = view.bounds
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.delegate = self
        scrollView.minimumZoomScale = 0.05
        scrollView.maximumZoomScale = 4
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        view.addSubview(scrollView)
        canvas.frame = CGRect(x: 0, y: 0, width: Board.canvasSize, height: Board.canvasSize)
        canvas.backgroundColor = .clear
        scrollView.addSubview(canvas)
        scrollView.contentSize = canvas.frame.size
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapCanvas))
        canvas.addGestureRecognizer(tap)

        emptyLabel.text = "Empty board\nSelect images in a folder and choose “Add to Board”,\nor use “Add Images from Files…” in the ⋯ menu."
        emptyLabel.numberOfLines = 0
        emptyLabel.textAlignment = .center
        emptyLabel.textColor = .secondaryLabel
        emptyLabel.font = .preferredFont(forTextStyle: .title3)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyLabel.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -64),
        ])

        // Labelled actions: what each does is clear without guessing from an icon.
        let more = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), menu: UIMenu(children: [
            UIAction(title: "Add Images from Files…", subtitle: "Pick images to place on this board",
                     image: UIImage(systemName: "photo.badge.plus")) { [weak self] _ in self?.pickImages() },
            UIAction(title: "Show Everything", subtitle: "Zoom to fit all images on screen",
                     image: UIImage(systemName: "rectangle.arrowtriangle.2.inward")) { [weak self] _ in self?.fitAll(animated: true) },
            UIMenu(options: .displayInline, children: [
                UIAction(title: "Export as Image", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in self?.export() },
                UIAction(title: "Rename…", image: UIImage(systemName: "pencil")) { [weak self] _ in self?.rename() },
            ]),
        ]))
        more.accessibilityLabel = "Board Options"
        navigationItem.rightBarButtonItems = [more]
        NotificationCenter.default.addObserver(forName: RootSplitViewController.sidebarDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.refitIfNeeded()
            // Once more after the sidebar has settled in its final place.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self?.refitIfNeeded() }
        }
        if presentingViewController != nil, navigationController?.viewControllers.first === self {
            navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .close, primaryAction: UIAction { [weak self] _ in
                self?.dismiss(animated: true)
            })
        }
        NotificationCenter.default.addObserver(forName: BoardStore.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.syncFromStore()
        }
        buildItems()
    }

    /// True while the view still shows "everything fitted": it then follows sidebar and rotation
    /// changes. Panning or zooming by hand turns it off until "Show Everything" is used again.
    private var isFitted = true
    private var lastVisibleArea: CGRect = .zero

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        refitIfNeeded(animated: lastVisibleArea != .zero)
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        refitIfNeeded()
    }

    private func refitIfNeeded(animated: Bool = true) {
        let area = visibleArea
        guard area.width > 0, area != lastVisibleArea else { return }
        lastVisibleArea = area
        if isFitted { fitAll(animated: animated) }
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { isFitted = false }
    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) { isFitted = false }

    /// The part of the screen not covered by bars or the floating sidebar, in this view's coordinates.
    private var visibleArea: CGRect {
        var area = view.bounds.inset(by: view.safeAreaInsets)
        if let split = splitViewController, !split.isCollapsed, split.displayMode != .secondaryOnly,
           let sidebar = split.viewController(for: .primary)?.view, sidebar.window != nil {
            let frame = sidebar.convert(sidebar.bounds, to: view)
            if frame.intersects(view.bounds), frame.maxX > area.minX, frame.minX <= view.bounds.minX + 1 {
                area = CGRect(x: frame.maxX, y: area.minY, width: max(area.maxX - frame.maxX, 0), height: area.height)
            }
        }
        return area
    }

    // MARK: Items

    private func buildItems() {
        itemViews.values.forEach { $0.removeFromSuperview() }
        itemViews = [:]
        for item in board.items { addView(for: item) }
        emptyLabel.isHidden = !board.items.isEmpty
    }

    private func addView(for item: BoardItem) {
        let url = BoardStore.shared.resolve(item)
        ScopedAccess.begin(url, owner: self)
        let itemView = BoardItemView(item: item, url: url)
        itemView.onChange = { [weak self] item in self?.itemChanged(item) }
        itemView.onSelect = { [weak self] view in self?.select(view) }
        itemView.menuProvider = { [weak self] view in self?.menu(for: view) }
        itemView.onOpen = { [weak self] view in self?.open(view) }
        canvas.addSubview(itemView)
        itemViews[item.id] = itemView
    }

    /// Picks up items added from elsewhere (e.g. "Add to Board" while this board is open).
    private func syncFromStore() {
        guard let stored = BoardStore.shared.board(board.id) else { return }
        let known = Set(board.items.map(\.id))
        let added = stored.items.filter { !known.contains($0.id) }
        board.name = stored.name
        title = board.name
        guard !added.isEmpty else { return }
        board.items += added
        added.forEach(addView(for:))
        emptyLabel.isHidden = true
    }

    private func itemChanged(_ item: BoardItem) {
        guard let index = board.items.firstIndex(where: { $0.id == item.id }) else { return }
        board.items[index] = item
        scheduleSave()
    }

    private func select(_ view: BoardItemView) {
        itemViews.values.forEach { $0.isSelected = $0 === view }
    }

    @objc private func tapCanvas() {
        itemViews.values.forEach { $0.isSelected = false }
    }

    private func bringToFront(_ view: BoardItemView) {
        canvas.bringSubviewToFront(view)
        if let index = board.items.firstIndex(where: { $0.id == view.item.id }) {
            board.items.append(board.items.remove(at: index))
            scheduleSave()
        }
    }

    private func sendToBack(_ view: BoardItemView) {
        canvas.sendSubviewToBack(view)
        if let index = board.items.firstIndex(where: { $0.id == view.item.id }) {
            board.items.insert(board.items.remove(at: index), at: 0)
            scheduleSave()
        }
    }

    private func remove(_ view: BoardItemView) {
        view.removeFromSuperview()
        itemViews[view.item.id] = nil
        board.items.removeAll { $0.id == view.item.id }
        emptyLabel.isHidden = !board.items.isEmpty
        scheduleSave()
    }

    private func menu(for view: BoardItemView) -> UIMenu {
        UIMenu(children: [
            UIAction(title: "Open", image: UIImage(systemName: "arrow.up.left.and.arrow.down.right")) { [weak self] _ in self?.open(view) },
            UIAction(title: "Bring to Front", image: UIImage(systemName: "square.3.layers.3d.top.filled")) { [weak self] _ in self?.bringToFront(view) },
            UIAction(title: "Send to Back", image: UIImage(systemName: "square.3.layers.3d.bottom.filled")) { [weak self] _ in self?.sendToBack(view) },
            UIAction(title: "Reset Rotation", image: UIImage(systemName: "rotate.left")) { _ in view.resetRotation() },
            UIAction(title: "Remove from Board", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                self?.remove(view)
            },
        ])
    }

    /// Opens the viewer on this image, paging through the board's images in layer order.
    private func open(_ view: BoardItemView) {
        let urls = board.items.map { itemViews[$0.id]?.url ?? BoardStore.shared.resolve($0) }
        let items = urls.compactMap { url -> ImageItem? in
            guard let values = try? url.resourceValues(forKeys: FolderScanner.keys) else { return nil }
            return ImageItem(url: url, size: values.fileSize ?? 0, modified: values.contentModificationDate ?? .distantPast)
        }
        let index = items.firstIndex { $0.url == view.url } ?? 0
        let viewer = ViewerViewController(items: items, index: index, showsControls: true)
        viewer.modalPresentationStyle = .fullScreen
        // Same zoom transition as the grid: grows out of the image and closes with a swipe down,
        // back into whichever board image is showing.
        let options = UIViewController.Transition.ZoomOptions()
        options.interactiveDismissShouldBegin = { [weak viewer] _ in viewer?.canInteractivelyDismiss ?? true }
        viewer.preferredTransition = .zoom(options: options) { [weak self] context in
            guard let self, let viewer = context.zoomedViewController as? ViewerViewController,
                  items.indices.contains(viewer.currentIndex) else { return nil }
            let url = items[viewer.currentIndex].url
            return self.itemViews.values.first { $0.url == url }
        }
        present(viewer, animated: true)
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            guard let self else { return }
            self.saveScheduled = false
            BoardStore.shared.update(self.board)
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if saveScheduled { BoardStore.shared.update(board) }
    }

    // MARK: Canvas

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { canvas }

    /// Bounding box of every item, in canvas coordinates.
    private var contentBounds: CGRect? {
        itemViews.values.map(\.frame).reduce(nil) { $0?.union($1) ?? $1 }
    }

    private func fitAll(animated: Bool) {
        guard let bounds = contentBounds else {
            let center = CGPoint(x: Board.center.x, y: Board.center.y)
            scrollView.zoomScale = 0.5
            scrollView.contentOffset = CGPoint(x: center.x * 0.5 - scrollView.bounds.width / 2,
                                               y: center.y * 0.5 - scrollView.bounds.height / 2)
            return
        }
        // Fit into the part of the screen not covered by the floating sidebar and bars.
        let visible = visibleArea.insetBy(dx: 40, dy: 40)
        guard visible.width > 0, visible.height > 0 else { return }
        let scale = min(max(min(visible.width / bounds.width, visible.height / bounds.height), scrollView.minimumZoomScale), 1.5)
        // Where the content's centre must land, relative to the scroll view's frame (not its bounds,
        // whose origin moves with the zoom).
        let target = view.convert(CGPoint(x: visible.midX, y: visible.midY), to: scrollView.superview)
        let anchor = CGPoint(x: target.x - scrollView.frame.minX, y: target.y - scrollView.frame.minY)
        let apply = {
            self.scrollView.zoomScale = scale
            self.scrollView.contentOffset = CGPoint(x: bounds.midX * scale - anchor.x, y: bounds.midY * scale - anchor.y)
        }
        animated ? UIView.animate(withDuration: 0.35, animations: apply) : apply()
        isFitted = true
    }

    // MARK: Adding

    private func pickImages() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.image])
        picker.allowsMultipleSelection = true
        picker.delegate = self
        present(picker, animated: true)
    }

    // MARK: Export

    /// Renders the whole board (up to 4096 px on the long side) and shares it.
    private func export() {
        guard let bounds = contentBounds?.insetBy(dx: -40, dy: -40) else { return }
        let scale = min(4096 / max(bounds.width, bounds.height), 2)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let ordered = board.items.compactMap { itemViews[$0.id] }
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            Theme.background.resolvedColor(with: traitCollection).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let cg = context.cgContext
            for view in ordered {
                guard let picture = view.image else { continue }
                cg.saveGState()
                cg.scaleBy(x: scale, y: scale)
                cg.translateBy(x: view.center.x - bounds.minX, y: view.center.y - bounds.minY)
                cg.rotate(by: CGFloat(view.item.rotation))
                let w = view.bounds.width, h = view.bounds.height
                picture.draw(in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
                cg.restoreGState()
            }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(board.name).png")
        guard (try? image.pngData()?.write(to: url)) != nil else { return }
        ShareSheet.present([url], from: self)
    }

    private func rename() {
        let alert = UIAlertController(title: "Rename Board", message: nil, preferredStyle: .alert)
        alert.addTextField { [board] in $0.text = board.name }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Rename", style: .default) { [weak self, weak alert] _ in
            guard let self, let name = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespaces), !name.isEmpty else { return }
            self.board.name = name
            self.title = name
            BoardStore.shared.update(self.board, notify: true)
        })
        present(alert, animated: true)
    }
}

extension BoardViewController: UIDocumentPickerDelegate {
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        // Picked files are security scoped: hold access while making their bookmarks.
        urls.forEach { ScopedAccess.begin($0, owner: self) }
        BoardStore.shared.add(urls, to: board.id)
    }
}

/// One image on a board, with its own move, resize and rotate gestures.
final class BoardItemView: UIView, UIGestureRecognizerDelegate, UIContextMenuInteractionDelegate {
    private(set) var item: BoardItem
    let url: URL
    var onChange: ((BoardItem) -> Void)?
    var onSelect: ((BoardItemView) -> Void)?
    var onOpen: ((BoardItemView) -> Void)?
    var menuProvider: ((BoardItemView) -> UIMenu?)?

    private let imageView = UIImageView()
    private var aspect: CGFloat = 1
    private var token: LoadToken?

    var image: UIImage? { imageView.image }

    var isSelected = false {
        didSet { layer.borderWidth = isSelected ? 3 : 0 }
    }

    init(item: BoardItem, url: URL) {
        self.item = item
        self.url = url
        super.init(frame: .zero)
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.backgroundColor = Settings.transparencyBackground.color
        imageView.layer.cornerRadius = 6
        imageView.layer.cornerCurve = .continuous
        imageView.frame = bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(imageView)
        layer.borderColor = Theme.accent.cgColor
        layer.cornerRadius = 6
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.4
        layer.shadowRadius = 12
        layer.shadowOffset = CGSize(width: 0, height: 6)
        isAccessibilityElement = true
        accessibilityLabel = url.lastPathComponent

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        let rotate = UIRotationGestureRecognizer(target: self, action: #selector(handleRotate(_:)))
        // One tap opens the image, like in the grid; dragging, pinching or twisting arranges it.
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        for recognizer in [pan, pinch, rotate] as [UIGestureRecognizer] {
            recognizer.delegate = self
            addGestureRecognizer(recognizer)
        }
        addGestureRecognizer(tap)
        addInteraction(UIContextMenuInteraction(delegate: self))
        applyGeometry()
        load()
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { ImagePipeline.thumbnails.cancel(token) }

    private func load() {
        let url = self.url
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let size = ImagePipeline.pixelSize(of: url)
            let values = try? url.resourceValues(forKeys: FolderScanner.keys)
            DispatchQueue.main.async {
                guard let self else { return }
                if let size, size.width > 0 { self.aspect = size.height / size.width }
                self.applyGeometry()
                let item = ImageItem(url: url, size: values?.fileSize ?? 0, modified: values?.contentModificationDate ?? .distantPast)
                self.token = ImagePipeline.thumbnails.load(.init(item, maxPixel: 1024), priority: .high) { [weak self] image in
                    self?.imageView.image = image ?? UIImage(systemName: "exclamationmark.triangle")
                    // Small sprites and pixel art scale up with hard edges.
                    if let image, max(image.size.width, image.size.height) * image.scale < 512 {
                        self?.imageView.layer.magnificationFilter = .nearest
                    }
                }
            }
        }
    }

    private func applyGeometry() {
        let width = CGFloat(item.width)
        bounds = CGRect(x: 0, y: 0, width: width, height: width * aspect)
        center = CGPoint(x: item.centerX, y: item.centerY)
        transform = CGAffineTransform(rotationAngle: CGFloat(item.rotation))
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: 6).cgPath
    }

    func resetRotation() {
        item.rotation = 0
        applyGeometry()
        onChange?(item)
    }

    // MARK: Gestures

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // Move, resize and rotate together, but never together with the canvas scroll view.
        other.view === self
    }

    @objc private func handlePan(_ pan: UIPanGestureRecognizer) {
        if pan.state == .began { onSelect?(self); superview?.bringSubviewToFront(self) }
        let translation = pan.translation(in: superview)
        item.centerX += Double(translation.x)
        item.centerY += Double(translation.y)
        pan.setTranslation(.zero, in: superview)
        applyGeometry()
        if pan.state == .ended || pan.state == .cancelled { onChange?(item) }
    }

    @objc private func handlePinch(_ pinch: UIPinchGestureRecognizer) {
        if pinch.state == .began { onSelect?(self) }
        item.width = min(max(item.width * Double(pinch.scale), 60), 8000)
        pinch.scale = 1
        applyGeometry()
        if pinch.state == .ended || pinch.state == .cancelled { onChange?(item) }
    }

    @objc private func handleRotate(_ rotation: UIRotationGestureRecognizer) {
        item.rotation += Double(rotation.rotation)
        rotation.rotation = 0
        applyGeometry()
        if rotation.state == .ended || rotation.state == .cancelled { onChange?(item) }
    }

    @objc private func handleTap() {
        onSelect?(self)
        onOpen?(self)
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard let menu = menuProvider?(self) else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in menu }
    }
}
