import CoreImage
import UIKit

/// Compares two images (e.g. a scene's art and its collision map): opacity overlay, onion skin,
/// difference, a draggable swipe divider, or side by side with synchronised zoom and pan.
final class CompareViewController: UIViewController, UIScrollViewDelegate {
    /// Raw values are stored; new modes are appended so saved choices keep their meaning.
    enum Mode: Int, CaseIterable {
        case overlay, swipe, sideBySide, onion, difference

        /// Order of the segments on screen.
        static let displayOrder: [Mode] = [.overlay, .onion, .difference, .swipe, .sideBySide]

        var title: String {
            switch self {
            case .overlay: return "Overlay"
            case .onion: return "Onion Skin"
            case .difference: return "Difference"
            case .swipe: return "Swipe"
            case .sideBySide: return "Side by Side"
            }
        }

        /// Modes drawn from images processed with Core Image.
        var isProcessed: Bool { self == .onion || self == .difference }
    }

    private var items: [ImageItem]
    private var images: [UIImage?] = [nil, nil]
    private var mode: Mode

    // Overlay and swipe share one zoomable surface, so both images always line up.
    private let sharedScroll = UIScrollView()
    private let container = UIView()
    private let baseView = UIImageView()
    private let topView = UIImageView()
    private let swipeMask = CALayer()
    /// Onion skin (A tinted red, B tinted cyan on top) or the difference image.
    private let processedBase = UIImageView()
    private let processedTop = UIImageView()
    private var processed: [Mode: (base: UIImage?, top: UIImage?)] = [:]
    private var processingGeneration = 0
    private static let ciContext = CIContext()
    private let divider = CompareDivider()
    private var dividerFraction: CGFloat = 0.5

    // Side by side.
    private let splitStack = UIStackView()
    private let leftScroll = UIScrollView()
    private let rightScroll = UIScrollView()
    private let leftView = UIImageView()
    private let rightView = UIImageView()
    private var isSyncing = false

    // Controls.
    private let topBar = GlassView()
    private let bottomBar = GlassView()
    private let modeControl = UISegmentedControl(items: Mode.displayOrder.map(\.title))
    private let opacitySlider = UISlider()
    private let firstLabel = UILabel()
    private let secondLabel = UILabel()
    private var lastBoundsSize: CGSize = .zero
    private var hiResWork: [DispatchWorkItem] = []

    private static let modeKey = "compareMode"

    init(first: ImageItem, second: ImageItem) {
        items = [first, second]
        mode = Mode(rawValue: UserDefaults.standard.integer(forKey: Self.modeKey)) ?? .overlay
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
        overrideUserInterfaceStyle = .dark
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { hiResWork.forEach { $0.cancel() } }

    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var prefersStatusBarHidden: Bool { true }
    override var canBecomeFirstResponder: Bool { true }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupShared()
        setupSideBySide()
        setupControls()
        NotificationCenter.default.addObserver(forName: TransparencyBackground.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.applyBackgrounds()
        }
        applyBackgrounds()
        updateLabels()
        loadImages()
        apply(mode: mode)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    private var lastPaneSize: CGSize = .zero

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if view.bounds.size != lastBoundsSize {
            lastBoundsSize = view.bounds.size
            splitStack.axis = view.bounds.width >= view.bounds.height ? .horizontal : .vertical
            // The stack lays out its panes in its own pass: settle it before measuring them.
            splitStack.setNeedsLayout()
            splitStack.layoutIfNeeded()
            layoutShared()
        }
        // Rotating changes the panes' size after the view's; relayout whenever they really change.
        if leftScroll.bounds.size != lastPaneSize {
            lastPaneSize = leftScroll.bounds.size
            layoutSplit()
        }
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            guard let self else { return }
            self.lastBoundsSize = .zero
            self.lastPaneSize = .zero
            self.view.setNeedsLayout()
            self.view.layoutIfNeeded()
        }
    }

    // MARK: Setup

    private func makeScrollView(_ scroll: UIScrollView) {
        scroll.delegate = self
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 16
        scroll.bouncesZoom = true
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)
    }

    private func setupShared() {
        makeScrollView(sharedScroll)
        sharedScroll.frame = view.bounds
        sharedScroll.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(sharedScroll)
        sharedScroll.addSubview(container)
        for imageView in [baseView, topView, processedBase, processedTop] {
            imageView.contentMode = .scaleAspectFit
            imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            container.addSubview(imageView)
        }
        swipeMask.backgroundColor = UIColor.black.cgColor

        divider.translatesAutoresizingMaskIntoConstraints = true
        divider.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(handleDividerPan(_:))))
        let centerTap = UITapGestureRecognizer(target: self, action: #selector(centerDivider))
        centerTap.numberOfTapsRequired = 2
        divider.addGestureRecognizer(centerTap)
        view.addSubview(divider)
    }

    private func setupSideBySide() {
        splitStack.distribution = .fillEqually
        splitStack.spacing = 2
        splitStack.frame = view.bounds
        splitStack.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        for (scroll, imageView) in [(leftScroll, leftView), (rightScroll, rightView)] {
            makeScrollView(scroll)
            imageView.contentMode = .scaleAspectFit
            scroll.addSubview(imageView)
            splitStack.addArrangedSubview(scroll)
        }
        view.addSubview(splitStack)
    }

    private func setupControls() {
        let close = UIButton(type: .system)
        close.setImage(UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)), for: .normal)
        close.tintColor = .white
        close.accessibilityLabel = "Close"
        close.addTarget(self, action: #selector(closeCompare), for: .primaryActionTriggered)

        let swap = UIButton(type: .system)
        swap.setImage(UIImage(systemName: "arrow.left.arrow.right", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)), for: .normal)
        swap.tintColor = .white
        swap.accessibilityLabel = "Swap Images"
        swap.addTarget(self, action: #selector(swapImages), for: .primaryActionTriggered)

        modeControl.selectedSegmentIndex = Mode.displayOrder.firstIndex(of: mode) ?? 0
        modeControl.addTarget(self, action: #selector(modeChanged), for: .valueChanged)

        let topStack = UIStackView(arrangedSubviews: [close, UIView(), modeControl, UIView(), swap])
        topStack.alignment = .center
        topStack.distribution = .equalCentering
        topStack.translatesAutoresizingMaskIntoConstraints = false
        topBar.contentView.addSubview(topStack)

        for label in [firstLabel, secondLabel] {
            label.font = .preferredFont(forTextStyle: .footnote)
            label.textColor = UIColor(white: 1, alpha: 0.85)
            label.lineBreakMode = .byTruncatingMiddle
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        secondLabel.textAlignment = .right
        opacitySlider.minimumValue = 0
        opacitySlider.maximumValue = 1
        opacitySlider.value = 0.5
        opacitySlider.minimumTrackTintColor = Theme.accent
        opacitySlider.accessibilityLabel = "Opacity of B"
        opacitySlider.addTarget(self, action: #selector(opacityChanged), for: .valueChanged)
        opacitySlider.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true

        let bottomStack = UIStackView(arrangedSubviews: [firstLabel, opacitySlider, secondLabel])
        bottomStack.spacing = 16
        bottomStack.alignment = .center
        bottomStack.translatesAutoresizingMaskIntoConstraints = false
        firstLabel.widthAnchor.constraint(equalTo: secondLabel.widthAnchor).isActive = true
        bottomBar.contentView.addSubview(bottomStack)

        view.addSubview(topBar)
        view.addSubview(bottomBar)
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: guide.topAnchor, constant: 14),
            topBar.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            topBar.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
            topStack.topAnchor.constraint(equalTo: topBar.contentView.topAnchor, constant: 4),
            topStack.bottomAnchor.constraint(equalTo: topBar.contentView.bottomAnchor, constant: -4),
            topStack.leadingAnchor.constraint(equalTo: topBar.contentView.leadingAnchor, constant: 8),
            topStack.trailingAnchor.constraint(equalTo: topBar.contentView.trailingAnchor, constant: -8),
            close.widthAnchor.constraint(equalToConstant: 44),
            close.heightAnchor.constraint(equalToConstant: 44),
            swap.widthAnchor.constraint(equalToConstant: 44),
            swap.heightAnchor.constraint(equalToConstant: 44),

            bottomBar.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -16),
            bottomBar.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            bottomBar.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
            bottomStack.topAnchor.constraint(equalTo: bottomBar.contentView.topAnchor, constant: 10),
            bottomStack.bottomAnchor.constraint(equalTo: bottomBar.contentView.bottomAnchor, constant: -10),
            bottomStack.leadingAnchor.constraint(equalTo: bottomBar.contentView.leadingAnchor, constant: 22),
            bottomStack.trailingAnchor.constraint(equalTo: bottomBar.contentView.trailingAnchor, constant: -22),
        ])
    }

    private func applyBackgrounds() {
        let background = Settings.transparencyBackground.color
        baseView.backgroundColor = background
        leftView.backgroundColor = background
        rightView.backgroundColor = background
        // In overlay mode A must show through B's transparent pixels; in swipe mode B hides A.
        topView.backgroundColor = mode == .swipe ? background : .clear
        processedBase.backgroundColor = .black
    }

    private func updateLabels() {
        firstLabel.text = "A  " + items[0].name
        secondLabel.text = items[1].name + "  B"
    }

    // MARK: Images

    private func loadImages() {
        for index in 0..<2 {
            let item = items[index]
            let request = ImagePipeline.Request(item, maxPixel: ZoomPageViewController.screenPixels)
            ImagePipeline.screen.load(request, priority: .veryHigh) { [weak self] image in
                guard let self, let image, self.items[index].url == item.url, self.images[index] == nil else { return }
                self.setImage(image, at: index)
            }
            // Then a sharper version for zooming in on details.
            let work = DispatchWorkItem { [weak self] in
                let original = ImagePipeline.pixelSize(of: item.url) ?? .zero
                let target = Int(min(max(original.width, original.height), 4096))
                guard target > ZoomPageViewController.screenPixels,
                      let cg = ImagePipeline.downsample(item.url, maxPixel: target) else { return }
                let image = UIImage(cgImage: cg)
                DispatchQueue.main.async {
                    guard let self, self.items[index].url == item.url else { return }
                    self.setImage(image, at: index)
                }
            }
            hiResWork.append(work)
            DispatchQueue.global(qos: .userInitiated).async(execute: work)
        }
    }

    private func setImage(_ image: UIImage, at index: Int) {
        let hadImage = images[index] != nil
        images[index] = image
        processed = [:]
        refreshImageViews()
        if mode.isProcessed { updateProcessed() }
        if !hadImage {
            layoutShared()
            layoutSplit()
        }
    }

    private func refreshImageViews() {
        baseView.image = images[0]
        topView.image = images[1]
        leftView.image = images[0]
        rightView.image = images[1]
    }

    // MARK: Layout

    /// Aspect-fit size of the reference image (A, or B until A arrives) inside `bounds`.
    private func fittedSize(in bounds: CGSize, for image: UIImage?) -> CGSize {
        guard let image = image ?? images[0] ?? images[1], image.size.width > 0, image.size.height > 0,
              bounds.width > 0, bounds.height > 0 else { return bounds }
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        return CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
    }

    private func layoutShared() {
        sharedScroll.zoomScale = 1
        let size = fittedSize(in: sharedScroll.bounds.size, for: images[0])
        container.frame = CGRect(origin: .zero, size: size)
        sharedScroll.contentSize = size
        center(sharedScroll)
        resetOffset(sharedScroll)
        layoutDivider()
        updateSwipeMask()
    }

    private func layoutSplit() {
        for (scroll, imageView, image) in [(leftScroll, leftView, images[0]), (rightScroll, rightView, images[1])] {
            scroll.zoomScale = 1
            let size = fittedSize(in: scroll.bounds.size, for: image)
            imageView.frame = CGRect(origin: .zero, size: size)
            scroll.contentSize = size
            center(scroll)
            resetOffset(scroll)
        }
    }

    private func center(_ scroll: UIScrollView) {
        let bounds = scroll.bounds.size
        let content = scroll.contentSize
        let insetX = max(0, (bounds.width - content.width) / 2)
        let insetY = max(0, (bounds.height - content.height) / 2)
        scroll.contentInset = UIEdgeInsets(top: insetY, left: insetX, bottom: insetY, right: insetX)
    }

    /// After a relayout at zoom 1 the old scroll position no longer fits: start from the centred image.
    private func resetOffset(_ scroll: UIScrollView) {
        scroll.contentOffset = CGPoint(x: -scroll.contentInset.left, y: -scroll.contentInset.top)
    }

    private func layoutDivider() {
        let x = (view.bounds.width * dividerFraction).rounded()
        divider.frame = CGRect(x: x - 22, y: 0, width: 44, height: view.bounds.height)
    }

    /// B is visible only to the right of the divider.
    private func updateSwipeMask() {
        guard mode == .swipe else { return }
        let dividerInTop = view.convert(CGPoint(x: view.bounds.width * dividerFraction, y: 0), to: topView).x
        let x = min(max(dividerInTop, 0), topView.bounds.width)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        swipeMask.frame = CGRect(x: x, y: 0, width: topView.bounds.width - x, height: topView.bounds.height)
        CATransaction.commit()
    }

    // MARK: Modes

    private func apply(mode: Mode) {
        self.mode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey)
        modeControl.selectedSegmentIndex = Mode.displayOrder.firstIndex(of: mode) ?? 0
        let shared = mode != .sideBySide
        sharedScroll.isHidden = !shared
        splitStack.isHidden = shared
        divider.isHidden = mode != .swipe
        opacitySlider.isHidden = mode != .overlay && mode != .onion
        baseView.isHidden = mode.isProcessed
        topView.isHidden = mode.isProcessed
        processedBase.isHidden = !mode.isProcessed
        processedTop.isHidden = mode != .onion

        switch mode {
        case .onion, .difference:
            processedTop.alpha = CGFloat(opacitySlider.value)
            updateProcessed()
        case .overlay:
            topView.layer.mask = nil
            topView.alpha = CGFloat(opacitySlider.value)
        case .swipe:
            topView.alpha = 1
            topView.layer.mask = swipeMask
            updateSwipeMask()
        case .sideBySide:
            layoutSplit()
        }
        applyBackgrounds()
    }

    @objc private func modeChanged() {
        let index = modeControl.selectedSegmentIndex
        apply(mode: Mode.displayOrder.indices.contains(index) ? Mode.displayOrder[index] : .overlay)
    }

    @objc private func opacityChanged() {
        topView.alpha = CGFloat(opacitySlider.value)
        processedTop.alpha = CGFloat(opacitySlider.value)
    }

    // MARK: Processed modes

    /// Shows (computing once, off the main thread) the onion skin or difference images.
    private func updateProcessed() {
        if let cached = processed[mode] {
            processedBase.image = cached.base
            processedTop.image = cached.top
            return
        }
        guard let a = images[0], let b = images[1] else { return }
        processingGeneration += 1
        let generation = processingGeneration
        let mode = self.mode
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Self.process(mode, a, b)
            DispatchQueue.main.async {
                guard let self, self.processingGeneration == generation else { return }
                self.processed[mode] = result
                if self.mode == mode {
                    self.processedBase.image = result.base
                    self.processedTop.image = result.top
                }
            }
        }
    }

    /// Both images on black at A's size (B fitted inside it), then tinted or differenced.
    static func process(_ mode: Mode, _ a: UIImage, _ b: UIImage) -> (base: UIImage?, top: UIImage?) {
        guard let cgA = a.cgImage, let cgB = b.cgImage else { return (nil, nil) }
        let extent = CGRect(x: 0, y: 0, width: cgA.width, height: cgA.height)
        let black = CIImage(color: .black).cropped(to: extent)
        let imageA = CIImage(cgImage: cgA).composited(over: black)
        var imageB = CIImage(cgImage: cgB)
        let scale = min(extent.width / imageB.extent.width, extent.height / imageB.extent.height)
        imageB = imageB.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        imageB = imageB.transformed(by: CGAffineTransform(translationX: (extent.width - imageB.extent.width) / 2,
                                                          y: (extent.height - imageB.extent.height) / 2))
        imageB = imageB.composited(over: black).cropped(to: extent)

        func render(_ image: CIImage) -> UIImage? {
            ciContext.createCGImage(image, from: extent).map { UIImage(cgImage: $0, scale: a.scale, orientation: .up) }
        }
        func tinted(_ image: CIImage, _ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CIImage {
            image.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: r, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: g, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: b, w: 0),
                ])
        }
        switch mode {
        case .onion:
            return (render(tinted(imageA, 1, 0.35, 0.3)), render(tinted(imageB, 0.25, 0.9, 1)))
        case .difference:
            // Boosted so faint changes stand out; identical areas stay black.
            let difference = imageB.applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: imageA])
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 3, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: 3, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 3, w: 0),
                ])
                .cropped(to: extent)
            return (render(difference), nil)
        default:
            return (nil, nil)
        }
    }

    @objc private func swapImages() {
        items.swapAt(0, 1)
        images.swapAt(0, 1)
        processed = [:]
        if mode.isProcessed { updateProcessed() }
        refreshImageViews()
        updateLabels()
        layoutShared()
        layoutSplit()
    }

    @objc private func closeCompare() {
        dismiss(animated: true)
    }

    // MARK: Gestures

    @objc private func handleDividerPan(_ pan: UIPanGestureRecognizer) {
        let x = pan.location(in: view).x
        dividerFraction = min(max(x / max(view.bounds.width, 1), 0), 1)
        layoutDivider()
        updateSwipeMask()
    }

    /// Double-tapping the divider puts it back in the middle.
    @objc private func centerDivider() {
        dividerFraction = 0.5
        UIView.animate(withDuration: 0.25) {
            self.layoutDivider()
            self.updateSwipeMask()
        }
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        guard let scroll = gesture.view as? UIScrollView, let content = viewForZooming(in: scroll) else { return }
        if scroll.zoomScale > 1.01 {
            scroll.setZoomScale(1, animated: true)
            return
        }
        let point = gesture.location(in: content)
        let scale: CGFloat = 3
        let size = CGSize(width: scroll.bounds.width / scale, height: scroll.bounds.height / scale)
        scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                               width: size.width, height: size.height), animated: true)
    }

    // MARK: UIScrollViewDelegate

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        switch scrollView {
        case sharedScroll: return container
        case leftScroll: return leftView
        case rightScroll: return rightView
        default: return nil
        }
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        center(scrollView)
        if scrollView === sharedScroll { updateSwipeMask() }
        sync(from: scrollView)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if scrollView === sharedScroll { updateSwipeMask() }
        sync(from: scrollView)
    }

    /// Mirrors zoom and position between the two side-by-side panes.
    private func sync(from scrollView: UIScrollView) {
        guard !isSyncing, scrollView === leftScroll || scrollView === rightScroll else { return }
        let other = scrollView === leftScroll ? rightScroll : leftScroll
        isSyncing = true
        other.zoomScale = scrollView.zoomScale
        center(other)
        other.contentOffset = scrollView.contentOffset
        isSyncing = false
    }

    // MARK: Keyboard

    override var keyCommands: [UIKeyCommand]? {
        let commands = [
            UIKeyCommand(title: "Flip A/B", action: #selector(flip), input: " "),
            UIKeyCommand(title: "Overlay", action: #selector(selectOverlay), input: "1"),
            UIKeyCommand(title: "Swipe", action: #selector(selectSwipe), input: "2"),
            UIKeyCommand(title: "Side by Side", action: #selector(selectSideBySide), input: "3"),
            UIKeyCommand(title: "Onion Skin", action: #selector(selectOnion), input: "4"),
            UIKeyCommand(title: "Difference", action: #selector(selectDifference), input: "5"),
            UIKeyCommand(title: "Swap", action: #selector(swapImages), input: "x"),
            UIKeyCommand(title: "Move Divider Left", action: #selector(dividerLeft), input: UIKeyCommand.inputLeftArrow),
            UIKeyCommand(title: "Move Divider Right", action: #selector(dividerRight), input: UIKeyCommand.inputRightArrow),
            UIKeyCommand(title: "Close", action: #selector(closeCompare), input: UIKeyCommand.inputEscape),
        ]
        commands.forEach { $0.wantsPriorityOverSystemBehavior = true }
        return commands
    }

    /// Instantly shows only A or only B, the quickest way to spot differences.
    @objc private func flip() {
        if mode != .overlay && mode != .onion { apply(mode: .overlay) }
        opacitySlider.value = opacitySlider.value < 0.5 ? 1 : 0
        opacityChanged()
    }

    @objc private func selectOverlay() { apply(mode: .overlay) }
    @objc private func selectSwipe() { apply(mode: .swipe) }
    @objc private func selectSideBySide() { apply(mode: .sideBySide) }
    @objc private func selectOnion() { apply(mode: .onion) }
    @objc private func selectDifference() { apply(mode: .difference) }

    @objc private func dividerLeft() { moveDivider(by: -0.05) }
    @objc private func dividerRight() { moveDivider(by: 0.05) }

    private func moveDivider(by delta: CGFloat) {
        if mode != .swipe { apply(mode: .swipe) }
        dividerFraction = min(max(dividerFraction + delta, 0), 1)
        layoutDivider()
        updateSwipeMask()
    }
}

/// The swipe divider: a thin line with a round handle. The view is wider than the line so it is easy to grab.
final class CompareDivider: UIView {
    private let line = UIView()
    private let handle = UIImageView(image: UIImage(systemName: "arrow.left.and.right.circle.fill",
                                                    withConfiguration: UIImage.SymbolConfiguration(pointSize: 36)))

    override init(frame: CGRect) {
        super.init(frame: frame)
        line.backgroundColor = .white
        line.layer.shadowColor = UIColor.black.cgColor
        line.layer.shadowOpacity = 0.5
        line.layer.shadowRadius = 2
        line.layer.shadowOffset = .zero
        addSubview(line)
        handle.tintColor = .white
        handle.layer.shadowColor = UIColor.black.cgColor
        handle.layer.shadowOpacity = 0.5
        handle.layer.shadowRadius = 4
        handle.layer.shadowOffset = .zero
        addSubview(handle)
        isAccessibilityElement = true
        accessibilityLabel = "Divider"
        accessibilityTraits = .adjustable
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        line.frame = CGRect(x: bounds.midX - 1, y: 0, width: 2, height: bounds.height)
        handle.sizeToFit()
        handle.center = CGPoint(x: bounds.midX, y: bounds.midY)
    }
}
