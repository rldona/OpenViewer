import UIKit

/// Full-screen paging viewer with neighbour preloading, a scrubber for huge collections,
/// a slideshow and keyboard control.
final class ViewerViewController: UIViewController {
    private let items: [ImageItem]
    private(set) var currentIndex: Int

    private let pageController = UIPageViewController(transitionStyle: .scroll, navigationOrientation: .horizontal,
                                                      options: [.interPageSpacing: 24])
    private let topBar = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    private let bottomBar = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let counterLabel = UILabel()
    private let scrubber = UISlider()
    private let playButton = UIButton(type: .system)
    private let infoButton = UIButton(type: .system)
    private let shareButton = UIButton(type: .system)
    private let favoriteButton = UIButton(type: .system)
    private let favoriteHUD = UIImageView()
    private let toastLabel = PaddedLabel()

    // Controls start hidden so the image gets the whole screen; a tap reveals them.
    private var chromeHidden = true
    private var slideshowTimer: Timer?
    private var startSlideshowOnAppear: Bool
    private var preloadTokens: [LoadToken] = []

    init(items: [ImageItem], index: Int, startSlideshow: Bool = false) {
        self.items = items
        self.currentIndex = min(max(index, 0), max(items.count - 1, 0))
        self.startSlideshowOnAppear = startSlideshow
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
        topBar.alpha = 0
        bottomBar.alpha = 0
        if !items.isEmpty {
            pageController.setViewControllers([makePage(currentIndex)], direction: .forward, animated: false)
        }
        didChangeIndex()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
        if startSlideshowOnAppear {
            startSlideshowOnAppear = false
            startSlideshow()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopSlideshow()
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
        playButton.menu = slideshowMenu()

        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingMiddle
        subtitleLabel.font = .preferredFont(forTextStyle: .caption1)
        subtitleLabel.textColor = UIColor(white: 1, alpha: 0.7)
        subtitleLabel.lineBreakMode = .byTruncatingHead
        let titles = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        titles.axis = .vertical

        let topStack = UIStackView(arrangedSubviews: [closeButton, titles, favoriteButton, playButton, infoButton, shareButton])
        topStack.alignment = .center
        topStack.spacing = 8
        topStack.translatesAutoresizingMaskIntoConstraints = false
        topBar.contentView.addSubview(topStack)

        counterLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        counterLabel.textColor = .white
        counterLabel.setContentHuggingPriority(.required, for: .horizontal)
        counterLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        scrubber.minimumValue = 0
        scrubber.maximumValue = Float(max(items.count - 1, 1))
        scrubber.minimumTrackTintColor = .white
        scrubber.addTarget(self, action: #selector(scrubbed), for: .valueChanged)
        scrubber.accessibilityLabel = "Position"
        let bottomStack = UIStackView(arrangedSubviews: [scrubber, counterLabel])
        bottomStack.spacing = 16
        bottomStack.alignment = .center
        bottomStack.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.contentView.addSubview(bottomStack)
        bottomBar.isHidden = items.count < 2

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

        for bar in [topBar, bottomBar] {
            bar.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(bar)
        }
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topStack.topAnchor.constraint(equalTo: guide.topAnchor, constant: 4),
            topStack.bottomAnchor.constraint(equalTo: topBar.bottomAnchor, constant: -4),
            topStack.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 8),
            topStack.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -8),

            bottomBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            bottomBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomStack.topAnchor.constraint(equalTo: bottomBar.topAnchor, constant: 10),
            bottomStack.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -10),
            bottomStack.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 24),
            bottomStack.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -24),
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
        }
        setNeedsUpdateOfHomeIndicatorAutoHidden()
    }

    @objc private func toggleChrome() { setChromeHidden(!chromeHidden) }

    // MARK: Navigation

    private func makePage(_ index: Int) -> ZoomPageViewController {
        let page = ZoomPageViewController(item: items[index], index: index)
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
        updateFavoriteButton()
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

    @objc private func showInfo() {
        guard !items.isEmpty else { return }
        stopSlideshow()
        let info = InfoViewController(item: items[currentIndex])
        let navigation = UINavigationController(rootViewController: info)
        navigation.modalPresentationStyle = .popover
        navigation.popoverPresentationController?.sourceView = infoButton
        navigation.preferredContentSize = CGSize(width: 360, height: 480)
        present(navigation, animated: true)
    }

    @objc private func share() {
        guard !items.isEmpty else { return }
        stopSlideshow()
        let activity = UIActivityViewController(activityItems: [items[currentIndex].url], applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = shareButton
        present(activity, animated: true)
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
