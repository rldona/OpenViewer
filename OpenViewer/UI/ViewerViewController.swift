import UIKit

/// Full-screen paging viewer with neighbour preloading, a scrubber for huge collections,
/// a slideshow and keyboard control.
final class ViewerViewController: UIViewController {
    private let items: [ImageItem]
    private(set) var currentIndex: Int

    private let pageController = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal,
                                                      options: [.interPageSpacing: 24])
    /// Holds the two top capsules; touches between them reach the image.
    private let topBar = PassthroughView()
    private let titleCapsule = GlassView()
    private let actionsCapsule = GlassView()
    private let bottomBar = GlassView(cornerRadius: 22)
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let counterLabel = UILabel()
    private let scrubber = UISlider()
    private lazy var filmstrip = FilmstripView(items: items)
    private let infoPanel = InfoPanelView()
    private var infoVisible = UserDefaults.standard.bool(forKey: "viewerInfoVisible")
    /// Collections this long also get a slider for big jumps above the filmstrip.
    private let scrubberThreshold = 200
    private let playButton = UIButton(type: .system)
    private let infoButton = UIButton(type: .system)
    private let shareButton = UIButton(type: .system)
    private let favoriteButton = UIButton(type: .system)
    private let animateButton = UIButton(type: .system)
    private let moreButton = UIButton(type: .system)
    private let favoriteHUD = UIImageView()
    private let toastLabel = PaddedLabel()

    // Controls start hidden so the image gets the whole screen; a tap reveals them.
    private var chromeHidden = true
    private var slideshowTimer: Timer?
    private var startSlideshowOnAppear: Bool
    private let showsControlsOnOpen: Bool
    private var preloadTokens: [LoadToken] = []

    /// `showsControls`: open with the controls on screen (e.g. from a board) instead of the bare image.
    init(items: [ImageItem], index: Int, startSlideshow: Bool = false, showsControls: Bool = false) {
        self.items = items
        self.currentIndex = min(max(index, 0), max(items.count - 1, 0))
        self.startSlideshowOnAppear = startSlideshow
        self.showsControlsOnOpen = showsControls
        super.init(nibName: nil, bundle: nil)
        overrideUserInterfaceStyle = .dark
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        preloadTokens.forEach { ImagePipeline.screen.cancel($0) }
    }

    var canInteractivelyDismiss: Bool {
        !((pageController.viewControllers?.first as? ZoomPageViewController)?.isZoomed ?? false)
    }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        addChild(pageController)
        pageController.view.frame = view.bounds
        pageController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(pageController.view)
        pageController.didMove(toParent: self)
        pageController.dataSource = self
        pageController.delegate = self

        setupChrome()
        if infoVisible { applyInfoVisibility(animated: false) }
        topBar.alpha = 0
        bottomBar.alpha = 0
        infoPanel.alpha = 0
        if showsControlsOnOpen { setChromeHidden(false) }
        if !items.isEmpty {
            pageController.setViewControllers([makePage(currentIndex)], direction: .forward, animated: false)
        }
        didChangeIndex()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
        if ExternalDisplay.shared.isConnected { showToast("Showing on the external display") }
        if startSlideshowOnAppear {
            startSlideshowOnAppear = false
            startSlideshow()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopSlideshow()
        // Back to the idle screen unless another viewer (e.g. from a board) takes over.
        if isBeingDismissed || presentingViewController == nil { ExternalDisplay.shared.show(nil) }
    }

    override var canBecomeFirstResponder: Bool { true }
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { chromeHidden }

    // MARK: Chrome

    private func setupChrome() {
        func configure(_ button: UIButton, symbol: String, label: String, action: Selector) {
            button.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)), for: .normal)
            button.tintColor = .white
            button.accessibilityLabel = label
            button.addTarget(self, action: action, for: .primaryActionTriggered)
            button.widthAnchor.constraint(equalToConstant: 44).isActive = true
            button.heightAnchor.constraint(equalToConstant: 44).isActive = true
        }
        let closeButton = UIButton(type: .system)
        configure(closeButton, symbol: "xmark", label: "Close", action: #selector(close))
        configure(playButton, symbol: "play.fill", label: "Slideshow", action: #selector(toggleSlideshow))
        configure(infoButton, symbol: "info.circle", label: "Info", action: #selector(showInfo))
        configure(shareButton, symbol: "square.and.arrow.up", label: "Share", action: #selector(share))
        configure(favoriteButton, symbol: "heart", label: "Favorite", action: #selector(toggleFavorite))
        configure(animateButton, symbol: "film.stack", label: "Play Frames as Animation", action: #selector(playFrames))
        moreButton.setImage(UIImage(systemName: "ellipsis.circle", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)), for: .normal)
        moreButton.tintColor = .white
        moreButton.accessibilityLabel = "More"
        moreButton.showsMenuAsPrimaryAction = true
        moreButton.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] provide in
            provide(self?.moreMenuElements() ?? [])
        }])
        moreButton.widthAnchor.constraint(equalToConstant: 44).isActive = true
        moreButton.heightAnchor.constraint(equalToConstant: 44).isActive = true
        playButton.menu = slideshowMenu()

        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingMiddle
        subtitleLabel.font = .preferredFont(forTextStyle: .caption1)
        subtitleLabel.textColor = UIColor(white: 1, alpha: 0.7)
        subtitleLabel.lineBreakMode = .byTruncatingHead
        let titles = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        titles.axis = .vertical

        let titleStack = UIStackView(arrangedSubviews: [closeButton, titles])
        titleStack.alignment = .center
        titleStack.spacing = 4
        titleCapsule.embed(titleStack, insets: NSDirectionalEdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 20))
        // Drag the title to drop the image file into another app or window.
        let drag = UIDragInteraction(delegate: self)
        drag.isEnabled = true
        titleCapsule.addInteraction(drag)
        let actionsStack = UIStackView(arrangedSubviews: [favoriteButton, animateButton, playButton, infoButton, shareButton, moreButton])
        actionsStack.alignment = .center
        actionsStack.spacing = 2
        actionsCapsule.embed(actionsStack, insets: NSDirectionalEdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6))
        topBar.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(titleCapsule)
        topBar.addSubview(actionsCapsule)

        counterLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        counterLabel.textColor = .white
        counterLabel.setContentHuggingPriority(.required, for: .horizontal)
        counterLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        scrubber.minimumValue = 0
        scrubber.maximumValue = Float(max(items.count - 1, 1))
        scrubber.minimumTrackTintColor = Theme.accent
        scrubber.addTarget(self, action: #selector(scrubbed), for: .valueChanged)
        scrubber.accessibilityLabel = "Position"
        filmstrip.onSelect = { [weak self] index in
            self?.stopSlideshow()
            self?.go(to: index, animated: false)
        }
        let stripRow = UIStackView(arrangedSubviews: [filmstrip, counterLabel])
        stripRow.spacing = 14
        stripRow.alignment = .center
        let bottomStack = UIStackView(arrangedSubviews: [scrubber, stripRow])
        bottomStack.axis = .vertical
        bottomStack.spacing = 4
        scrubber.isHidden = items.count < scrubberThreshold
        bottomBar.embed(bottomStack, insets: NSDirectionalEdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 18))
        bottomBar.isHidden = items.count < 2
        bottomBar.layer.cornerRadius = 22

        infoPanel.translatesAutoresizingMaskIntoConstraints = false
        infoPanel.onMessage = { [weak self] text in self?.showToast(text) }
        infoPanel.isHidden = true

        favoriteHUD.image = UIImage(systemName: "heart.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 72, weight: .medium))
        favoriteHUD.tintColor = .white
        favoriteHUD.alpha = 0
        favoriteHUD.layer.shadowColor = UIColor.black.cgColor
        favoriteHUD.layer.shadowOpacity = 0.4
        favoriteHUD.layer.shadowRadius = 12
        favoriteHUD.layer.shadowOffset = .zero
        favoriteHUD.isUserInteractionEnabled = false
        favoriteHUD.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(favoriteHUD)
        NSLayoutConstraint.activate([
            favoriteHUD.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            favoriteHUD.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        toastLabel.font = .preferredFont(forTextStyle: .headline)
        toastLabel.textColor = .white
        toastLabel.backgroundColor = UIColor(white: 0, alpha: 0.6)
        toastLabel.layer.cornerRadius = 12
        toastLabel.layer.cornerCurve = .continuous
        toastLabel.clipsToBounds = true
        toastLabel.alpha = 0
        toastLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(toastLabel)
        NSLayoutConstraint.activate([
            toastLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            toastLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -96),
        ])

        view.addSubview(topBar)
        view.addSubview(bottomBar)
        view.addSubview(infoPanel)
        let guide = view.safeAreaLayoutGuide
        let bottomWidth = bottomBar.widthAnchor.constraint(equalToConstant: 900)
        bottomWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: guide.topAnchor, constant: 14),
            topBar.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            topBar.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
            titleCapsule.topAnchor.constraint(equalTo: topBar.topAnchor),
            titleCapsule.bottomAnchor.constraint(equalTo: topBar.bottomAnchor),
            titleCapsule.leadingAnchor.constraint(equalTo: topBar.leadingAnchor),
            titleCapsule.trailingAnchor.constraint(lessThanOrEqualTo: actionsCapsule.leadingAnchor, constant: -12),
            actionsCapsule.centerYAnchor.constraint(equalTo: titleCapsule.centerYAnchor),
            actionsCapsule.trailingAnchor.constraint(equalTo: topBar.trailingAnchor),

            bottomBar.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -16),
            bottomBar.leadingAnchor.constraint(greaterThanOrEqualTo: guide.leadingAnchor, constant: 24),
            bottomBar.trailingAnchor.constraint(lessThanOrEqualTo: guide.trailingAnchor, constant: -24),
            bottomWidth,

            infoPanel.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 12),
            infoPanel.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
            infoPanel.bottomAnchor.constraint(lessThanOrEqualTo: bottomBar.topAnchor, constant: -12),
        ])
    }

    private func slideshowMenu() -> UIMenu {
        let current = Settings.slideshowInterval
        return UIMenu(title: "Slideshow Interval", children: [2, 3, 5, 10].map { seconds in
            UIAction(title: "\(Int(seconds)) seconds", state: current == seconds ? .on : .off) { [weak self] _ in
                Settings.slideshowInterval = seconds
                self?.playButton.menu = self?.slideshowMenu()
                if self?.slideshowTimer != nil { self?.startSlideshow() }
            }
        })
    }

    private func setChromeHidden(_ hidden: Bool) {
        guard hidden != chromeHidden else { return }
        chromeHidden = hidden
        UIView.animate(withDuration: 0.2) {
            self.topBar.alpha = hidden ? 0 : 1
            self.bottomBar.alpha = hidden ? 0 : 1
            self.infoPanel.alpha = hidden ? 0 : 1
        }
        setNeedsUpdateOfHomeIndicatorAutoHidden()
    }

    @objc private func toggleChrome() { setChromeHidden(!chromeHidden) }

    // MARK: Navigation

    private func makePage(_ index: Int) -> ZoomPageViewController {
        let page = ZoomPageViewController(item: items[index], index: index)
        page.onMessage = { [weak self] text in self?.showToast(text) }
        page.onSingleTap = { [weak self] in
            self?.stopSlideshow()
            self?.toggleChrome()
        }
        return page
    }

    func go(to index: Int, animated: Bool) {
        guard !items.isEmpty else { return }
        let target = min(max(index, 0), items.count - 1)
        guard target != currentIndex else { return }
        let direction: UIPageViewController.NavigationDirection = target > currentIndex ? .forward : .reverse
        currentIndex = target
        pageController.setViewControllers([makePage(target)], direction: direction, animated: animated)
        didChangeIndex()
    }

    private func didChangeIndex() {
        guard !items.isEmpty else { return }
        let item = items[currentIndex]
        titleLabel.text = item.name
        subtitleLabel.text = item.url.deletingLastPathComponent().lastPathComponent
        counterLabel.text = "\((currentIndex + 1).formatted()) / \(items.count.formatted())"
        if !scrubber.isTracking { scrubber.value = Float(currentIndex) }
        filmstrip.select(currentIndex, animated: true)
        if infoVisible { infoPanel.show(item) }
        updateFavoriteButton()
        ExternalDisplay.shared.show(item)
        // Only numbered names ("walk_03.png") can be part of a frame sequence.
        animateButton.isHidden = FrameSequence.stem(of: item.name) == nil
        preloadNeighbours()
    }

    /// Decodes the next two and the previous image so paging feels instant.
    private func preloadNeighbours() {
        preloadTokens.forEach { ImagePipeline.screen.cancel($0) }
        preloadTokens = [currentIndex + 1, currentIndex - 1, currentIndex + 2].compactMap { index in
            guard items.indices.contains(index) else { return nil }
            return ImagePipeline.screen.prefetch(.init(items[index], maxPixel: ZoomPageViewController.screenPixels))
        }
    }

    @objc private func scrubbed() {
        stopSlideshow()
        go(to: Int(scrubber.value.rounded()), animated: false)
    }

    @objc func showNext() { go(to: currentIndex + 1, animated: true) }
    @objc func showPrevious() { go(to: currentIndex - 1, animated: true) }
    @objc private func first() { go(to: 0, animated: false) }
    @objc private func last() { go(to: items.count - 1, animated: false) }

    @objc private func close() {
        stopSlideshow()
        dismiss(animated: true)
    }

    // MARK: Slideshow

    @objc private func toggleSlideshow() {
        slideshowTimer == nil ? startSlideshow() : stopSlideshow()
    }

    private func startSlideshow() {
        guard items.count > 1 else { return }
        slideshowTimer?.invalidate()
        slideshowTimer = Timer.scheduledTimer(withTimeInterval: Settings.slideshowInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.currentIndex >= self.items.count - 1 {
                self.go(to: 0, animated: false)
            } else {
                self.go(to: self.currentIndex + 1, animated: true)
            }
        }
        UIApplication.shared.isIdleTimerDisabled = true
        playButton.setImage(UIImage(systemName: "pause.fill"), for: .normal)
        setChromeHidden(true)
    }

    private func stopSlideshow() {
        guard slideshowTimer != nil else { return }
        slideshowTimer?.invalidate()
        slideshowTimer = nil
        UIApplication.shared.isIdleTimerDisabled = false
        playButton.setImage(UIImage(systemName: "play.fill"), for: .normal)
    }

    // MARK: Actions

    // MARK: Favorites

    private func updateFavoriteButton() {
        guard !items.isEmpty else { return }
        let isFavorite = FavoritesStore.shared.contains(items[currentIndex].url)
        favoriteButton.setImage(UIImage(systemName: isFavorite ? "heart.fill" : "heart",
                                         withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)), for: .normal)
        favoriteButton.tintColor = isFavorite ? .systemPink : .white
        favoriteButton.accessibilityLabel = isFavorite ? "Remove from Favorites" : "Add to Favorites"
    }

    @objc private func toggleFavorite() {
        guard !items.isEmpty else { return }
        let isFavorite = FavoritesStore.shared.toggle(items[currentIndex].url)
        updateFavoriteButton()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        showFavoriteHUD(isFavorite)
    }

    /// Brief centred heart so the change is visible even with the controls hidden.
    private func showFavoriteHUD(_ isFavorite: Bool) {
        favoriteHUD.image = UIImage(systemName: isFavorite ? "heart.fill" : "heart.slash.fill",
                                    withConfiguration: UIImage.SymbolConfiguration(pointSize: 72, weight: .medium))
        favoriteHUD.layer.removeAllAnimations()
        favoriteHUD.alpha = 1
        favoriteHUD.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
        UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.5, initialSpringVelocity: 0) {
            self.favoriteHUD.transform = .identity
        }
        UIView.animate(withDuration: 0.3, delay: 0.6, options: [.beginFromCurrentState]) {
            self.favoriteHUD.alpha = 0
        }
    }

    // MARK: Transparency

    @objc private func cycleTransparencyBackground() {
        let next = Settings.transparencyBackground.next
        Settings.transparencyBackground = next
        showToast("Background: \(next.title)")
    }

    private func showToast(_ text: String) {
        toastLabel.text = text
        toastLabel.layer.removeAllAnimations()
        toastLabel.alpha = 1
        UIView.animate(withDuration: 0.3, delay: 1.0, options: [.beginFromCurrentState]) {
            self.toastLabel.alpha = 0
        }
    }

    /// Toggles the floating info card; the choice is remembered.
    @objc private func showInfo() {
        guard !items.isEmpty else { return }
        infoVisible.toggle()
        UserDefaults.standard.set(infoVisible, forKey: "viewerInfoVisible")
        applyInfoVisibility(animated: true)
    }

    private func applyInfoVisibility(animated: Bool) {
        infoButton.backgroundColor = infoVisible ? UIColor(white: 1, alpha: 0.2) : .clear
        infoButton.layer.cornerRadius = 22
        infoButton.accessibilityTraits = infoVisible ? [.button, .selected] : .button
        if infoVisible {
            infoPanel.show(items[currentIndex])
            // Turning it on reveals the controls; opening the viewer keeps them (and the card) hidden.
            if animated { setChromeHidden(false) }
        }
        let changes = { self.infoPanel.isHidden = !self.infoVisible }
        animated ? UIView.transition(with: infoPanel, duration: 0.2, options: .transitionCrossDissolve, animations: changes) : changes()
    }

    // MARK: More menu

    private func moreMenuElements() -> [UIMenuElement] {
        guard !items.isEmpty else { return [] }
        let item = items[currentIndex]
        let similar = UIAction(title: "Find Similar Images", image: UIImage(systemName: "sparkle.magnifyingglass")) { [weak self] _ in
            self?.findSimilar()
        }
        let copyName = UIAction(title: "Copy Name", image: UIImage(systemName: "doc.on.doc")) { _ in
            UIPasteboard.general.string = item.name
        }
        let store = TagStore.shared
        let tags = UIMenu(title: "Tags", image: UIImage(systemName: "tag"), children: TagColor.allCases.map { tag in
            let has = store.has(tag, item.url)
            return UIAction(title: tag.title, image: tag.dot, state: has ? .on : .off) { [weak self] _ in
                store.set(tag, on: [item.url], !has)
                self?.showToast(has ? "Removed \(tag.title) tag" : "Tagged \(tag.title)")
            }
        })
        let board = BoardPrompt.menu(from: self, urls: { [item.url] }) { [weak self] board in
            self?.showToast("Added to \(board.name)")
        }
        return [tags, board, similar, copyName]
    }

    /// Images among this viewer's list that look like the current one.
    @objc private func findSimilar() {
        guard !items.isEmpty else { return }
        stopSlideshow()
        let item = items[currentIndex]
        let items = self.items
        runAnalysis(.visual, on: items, title: "Finding Similar Images") { [weak self] in
            guard let self else { return }
            if let collection = AnalysisFlows.similar(to: item, in: items) {
                self.presentCollection(collection)
            } else {
                self.showToast("Nothing similar found")
            }
        }
    }

    /// Plays the numbered frames this image belongs to as an animation.
    @objc private func playFrames() {
        guard !items.isEmpty else { return }
        stopSlideshow()
        let item = items[currentIndex]
        let frames = FrameSequence.frames(around: item, in: items)
        guard frames.count > 1 else {
            showToast("No numbered frames next to this image")
            return
        }
        present(FlipbookViewController(frames: frames, startAt: frames.firstIndex(of: item) ?? 0), animated: true)
    }

    @objc private func share() {
        guard !items.isEmpty else { return }
        stopSlideshow()
        ShareSheet.present([items[currentIndex].url], preview: items[currentIndex], from: self)
    }

    override var keyCommands: [UIKeyCommand]? {
        let commands = [
            UIKeyCommand(title: "Next", action: #selector(showNext), input: UIKeyCommand.inputRightArrow),
            UIKeyCommand(title: "Previous", action: #selector(showPrevious), input: UIKeyCommand.inputLeftArrow),
            UIKeyCommand(title: "Next", action: #selector(showNext), input: UIKeyCommand.inputDownArrow),
            UIKeyCommand(title: "Previous", action: #selector(showPrevious), input: UIKeyCommand.inputUpArrow),
            UIKeyCommand(title: "Next", action: #selector(showNext), input: " "),
            UIKeyCommand(title: "Previous", action: #selector(showPrevious), input: " ", modifierFlags: .shift),
            UIKeyCommand(title: "First", action: #selector(first), input: UIKeyCommand.inputHome),
            UIKeyCommand(title: "Last", action: #selector(last), input: UIKeyCommand.inputEnd),
            UIKeyCommand(title: "Close", action: #selector(close), input: UIKeyCommand.inputEscape),
            UIKeyCommand(title: "Info", action: #selector(showInfo), input: "i"),
            UIKeyCommand(title: "Favorite", action: #selector(toggleFavorite), input: "f"),
            UIKeyCommand(title: "Transparency Background", action: #selector(cycleTransparencyBackground), input: "b"),
            UIKeyCommand(title: "Slideshow", action: #selector(toggleSlideshow), input: "s"),
            UIKeyCommand(title: "Toggle Controls", action: #selector(toggleChrome), input: "h"),
            UIKeyCommand(title: "Play Frames as Animation", action: #selector(playFrames), input: "a"),
        ]
        commands.forEach { $0.wantsPriorityOverSystemBehavior = true }
        return commands
    }
}

extension ViewerViewController: UIPageViewControllerDataSource, UIPageViewControllerDelegate {
    func pageViewController(_ pageViewController: UIPageViewController,
                            viewControllerBefore viewController: UIViewController) -> UIViewController? {
        guard let page = viewController as? ZoomPageViewController, page.index > 0 else { return nil }
        return makePage(page.index - 1)
    }

    func pageViewController(_ pageViewController: UIPageViewController,
                            viewControllerAfter viewController: UIViewController) -> UIViewController? {
        guard let page = viewController as? ZoomPageViewController, page.index < items.count - 1 else { return nil }
        return makePage(page.index + 1)
    }

    func pageViewController(_ pageViewController: UIPageViewController, willTransitionTo pendingViewControllers: [UIViewController]) {
        // Only called for gesture-driven transitions: the user took over.
        stopSlideshow()
    }

    func pageViewController(_ pageViewController: UIPageViewController, didFinishAnimating finished: Bool,
                            previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
        guard completed, let page = pageViewController.viewControllers?.first as? ZoomPageViewController else { return }
        currentIndex = page.index
        didChangeIndex()
    }
}

extension ViewerViewController: UIDragInteractionDelegate {
    func dragInteraction(_ interaction: UIDragInteraction, itemsForBeginning session: UIDragSession) -> [UIDragItem] {
        guard !items.isEmpty else { return [] }
        let item = BrowserViewController.dragItem(for: items[currentIndex])
        let page = pageController.viewControllers?.first as? ZoomPageViewController
        if let image = page?.displayedImage {
            item.previewProvider = {
                let view = UIImageView(image: image)
                view.contentMode = .scaleAspectFit
                view.frame = CGRect(x: 0, y: 0, width: 220, height: 220 * image.size.height / max(image.size.width, 1))
                return UIDragPreview(view: view)
            }
        }
        return [item]
    }
}

/// Label with comfortable padding, used for short on-screen messages.
final class PaddedLabel: UILabel {
    var insets = UIEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + insets.left + insets.right, height: size.height + insets.top + insets.bottom)
    }
}

/// A container that lets touches through except where it has visible subviews.
final class PassthroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}
