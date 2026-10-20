import ImageIO
import UIKit

/// Finds the run of numbered frames an image belongs to ("attack_01.png", "attack_02.png"…).
enum FrameSequence {
    /// The name without extension and without its trailing frame number and separators,
    /// or nil when the name doesn't end in a number.
    static func stem(of name: String) -> String? {
        let base = (name as NSString).deletingPathExtension
        let trimmed = base.replacingOccurrences(of: "[\\s_\\-.]*\\d+$", with: "", options: .regularExpression)
        return trimmed == base ? nil : trimmed.lowercased()
    }

    /// Images in the same folder with the same stem, in natural name order (at least two, or empty).
    static func frames(around item: ImageItem, in items: [ImageItem]) -> [ImageItem] {
        guard let stem = stem(of: item.name) else { return [] }
        let folder = item.url.deletingLastPathComponent()
        let frames = items.filter {
            $0.url.deletingLastPathComponent() == folder && Self.stem(of: $0.name) == stem
        }
        guard frames.count > 1 else { return [] }
        return frames.sorted(by: SortOrder(key: .name, ascending: true))
    }
}

/// Plays a list of images as an animation (sprite frames, storyboards…), with speed, loop modes
/// and frame stepping. Frames are decoded once at a size that keeps the whole run within a fixed
/// memory budget, and keep their relative sizes so trimmed sprites don't jump around.
final class FlipbookViewController: UIViewController {
    enum Mode: String, CaseIterable {
        case loop, pingPong, once
        var title: String {
            switch self {
            case .loop: return "Loop"
            case .pingPong: return "Ping-Pong"
            case .once: return "Play Once"
            }
        }
    }

    static let speeds = [4, 6, 8, 12, 15, 24, 30, 60]
    /// Upper bound for all decoded frames together.
    private static let memoryBudget = 600 * 1024 * 1024

    private let frames: [ImageItem]
    private var images: [UIImage?]
    private var pixelSizes: [CGSize]
    private var current: Int
    private var direction = 1
    private var isPlaying = false
    private var fps = UserDefaults.standard.object(forKey: "flipbookFPS") as? Int ?? 12
    private var mode = Mode(rawValue: UserDefaults.standard.string(forKey: "flipbookMode") ?? "") ?? .loop
    private var displayLink: CADisplayLink?
    private var accumulated: CFTimeInterval = 0
    private var lastTimestamp: CFTimeInterval = 0
    private var loadedCount = 0
    private var cancelled = false

    private let canvas = UIView()
    private let imageView = UIImageView()
    private let topBar = GlassView()
    private let bottomBar = GlassView(cornerRadius: 22)
    private let titleLabel = UILabel()
    private let counterLabel = UILabel()
    private let playButton = UIButton(type: .system)
    private let speedButton = UIButton(type: .system)
    private let modeButton = UIButton(type: .system)
    private let scrubber = UISlider()
    private let progress = UIProgressView(progressViewStyle: .bar)

    init(frames: [ImageItem], startAt index: Int = 0) {
        self.frames = frames
        images = Array(repeating: nil, count: frames.count)
        pixelSizes = Array(repeating: .zero, count: frames.count)
        current = min(max(index, 0), max(frames.count - 1, 0))
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
        overrideUserInterfaceStyle = .dark
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { cancelled = true }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var canBecomeFirstResponder: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        canvas.frame = view.bounds
        canvas.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(canvas)
        imageView.contentMode = .scaleToFill
        imageView.backgroundColor = Settings.transparencyBackground.color
        imageView.layer.magnificationFilter = .nearest
        canvas.addSubview(imageView)
        setupChrome()
        loadFrames()
        show(current)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        pause()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        layoutFrame()
    }

    // MARK: Chrome

    private func setupChrome() {
        func symbol(_ name: String) -> UIImage? {
            UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .medium))
        }
        func button(_ name: String, _ label: String, _ action: @escaping () -> Void) -> UIButton {
            let button = UIButton(type: .system, primaryAction: UIAction { _ in action() })
            button.setImage(symbol(name), for: .normal)
            button.tintColor = .white
            button.accessibilityLabel = label
            button.widthAnchor.constraint(equalToConstant: 44).isActive = true
            button.heightAnchor.constraint(equalToConstant: 44).isActive = true
            return button
        }
        let close = button("xmark", "Close") { [weak self] in self?.dismiss(animated: true) }
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingMiddle
        let titleStack = UIStackView(arrangedSubviews: [close, titleLabel])
        titleStack.alignment = .center
        titleStack.spacing = 4
        topBar.embed(titleStack, insets: NSDirectionalEdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 20))

        playButton.setImage(symbol("play.fill"), for: .normal)
        playButton.tintColor = .white
        playButton.accessibilityLabel = "Play"
        playButton.addAction(UIAction { [weak self] _ in self?.togglePlay() }, for: .primaryActionTriggered)
        playButton.widthAnchor.constraint(equalToConstant: 44).isActive = true
        let back = button("backward.frame.fill", "Previous Frame") { [weak self] in self?.step(-1) }
        let forward = button("forward.frame.fill", "Next Frame") { [weak self] in self?.step(1) }

        for menuButton in [speedButton, modeButton] {
            var config = UIButton.Configuration.gray()
            config.cornerStyle = .capsule
            config.baseForegroundColor = .white
            config.buttonSize = .small
            menuButton.configuration = config
            menuButton.showsMenuAsPrimaryAction = true
        }
        updateMenus()

        scrubber.minimumValue = 0
        scrubber.maximumValue = Float(max(frames.count - 1, 1))
        scrubber.minimumTrackTintColor = Theme.accent
        scrubber.accessibilityLabel = "Frame"
        scrubber.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.pause()
            self.show(Int(self.scrubber.value.rounded()))
        }, for: .valueChanged)
        scrubber.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true

        counterLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        counterLabel.textColor = .white
        counterLabel.setContentHuggingPriority(.required, for: .horizontal)
        counterLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [back, playButton, forward, scrubber, counterLabel, speedButton, modeButton])
        row.alignment = .center
        row.spacing = 10
        row.setCustomSpacing(16, after: forward)
        progress.progressTintColor = Theme.accent
        progress.trackTintColor = .clear
        let stack = UIStackView(arrangedSubviews: [row, progress])
        stack.axis = .vertical
        stack.spacing = 2
        bottomBar.embed(stack, insets: NSDirectionalEdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 14))

        view.addSubview(topBar)
        view.addSubview(bottomBar)
        let guide = view.safeAreaLayoutGuide
        let width = bottomBar.widthAnchor.constraint(equalToConstant: 860)
        width.priority = .defaultHigh
        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: guide.topAnchor, constant: 14),
            topBar.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            topBar.trailingAnchor.constraint(lessThanOrEqualTo: guide.trailingAnchor, constant: -16),
            bottomBar.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -16),
            bottomBar.leadingAnchor.constraint(greaterThanOrEqualTo: guide.leadingAnchor, constant: 16),
            bottomBar.trailingAnchor.constraint(lessThanOrEqualTo: guide.trailingAnchor, constant: -16),
            width,
        ])
        let tap = UITapGestureRecognizer(target: self, action: #selector(togglePlay))
        canvas.addGestureRecognizer(tap)
    }

    private func updateMenus() {
        speedButton.configuration?.title = "\(fps) fps"
        speedButton.menu = UIMenu(title: "Speed", children: Self.speeds.map { value in
            UIAction(title: "\(value) fps", state: value == fps ? .on : .off) { [weak self] _ in
                self?.fps = value
                UserDefaults.standard.set(value, forKey: "flipbookFPS")
                self?.updateMenus()
            }
        })
        modeButton.configuration?.image = UIImage(systemName: mode == .loop ? "repeat" : mode == .pingPong ? "arrow.left.arrow.right" : "arrow.right.to.line")
        modeButton.accessibilityLabel = mode.title
        modeButton.menu = UIMenu(title: "Playback", children: Mode.allCases.map { option in
            UIAction(title: option.title, state: option == mode ? .on : .off) { [weak self] _ in
                self?.mode = option
                UserDefaults.standard.set(option.rawValue, forKey: "flipbookMode")
                self?.updateMenus()
            }
        })
    }

    // MARK: Frames

    /// Decodes every frame once, at a size that keeps them all within the memory budget.
    private func loadFrames() {
        let frames = self.frames
        progress.isHidden = frames.count < 2
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let sizes = frames.map { ImagePipeline.pixelSize(of: $0.url) ?? .zero }
            let largest = sizes.map { max($0.width, $0.height) }.max() ?? 0
            let perFrame = Double(Self.memoryBudget) / Double(max(frames.count, 1)) / 4
            let budgetSide = Int(perFrame.squareRoot())
            let screen = ZoomPageViewController.screenPixels
            let maxSide = max(64, min(screen, budgetSide, Int(largest)))
            let scale = largest > 0 ? min(1, CGFloat(maxSide) / largest) : 1
            DispatchQueue.main.async {
                self?.pixelSizes = sizes
                self?.layoutFrame()
            }
            // Start at the frame on screen, then fill in the rest in order.
            let start = self?.current ?? 0
            let order = Array(frames.indices[start...]) + Array(frames.indices[..<start])
            DispatchQueue.concurrentPerform(iterations: order.count) { position in
                guard let self, !self.cancelled else { return }
                let index = order[position]
                let side = max(Int((max(sizes[index].width, sizes[index].height) * scale).rounded()), 16)
                let image = ImagePipeline.downsample(frames[index].url, maxPixel: side).map { UIImage(cgImage: $0) }
                DispatchQueue.main.async {
                    self.images[index] = image
                    self.loadedCount += 1
                    self.progress.setProgress(Float(self.loadedCount) / Float(frames.count), animated: false)
                    if self.loadedCount == frames.count { UIView.animate(withDuration: 0.3) { self.progress.alpha = 0 } }
                    if index == self.current { self.show(index) }
                }
            }
        }
    }

    private func show(_ index: Int) {
        guard frames.indices.contains(index) else { return }
        current = index
        if let image = images[index] {
            imageView.image = image
        } else if imageView.image == nil {
            imageView.image = ImagePipeline.thumbnails.cachedImage(for: .init(frames[index], maxPixel: 512))
        }
        titleLabel.text = frames[index].name
        counterLabel.text = "\(index + 1) / \(frames.count)"
        if !scrubber.isTracking { scrubber.value = Float(index) }
        layoutFrame()
    }

    /// Every frame uses one scale (fitting the largest), so differently sized frames keep their proportions.
    private func layoutFrame() {
        let bounds = canvas.bounds.inset(by: UIEdgeInsets(top: 72, left: 16, bottom: 96, right: 16))
        guard bounds.width > 0, frames.indices.contains(current) else { return }
        var size = pixelSizes[current]
        if size == .zero, let image = imageView.image { size = image.size }
        let largest = CGSize(width: pixelSizes.map(\.width).max() ?? size.width,
                             height: pixelSizes.map(\.height).max() ?? size.height)
        guard size.width > 0, largest.width > 0, largest.height > 0 else { return }
        let scale = min(bounds.width / largest.width, bounds.height / largest.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        imageView.frame = CGRect(x: bounds.midX - fitted.width / 2, y: bounds.midY - fitted.height / 2,
                                 width: fitted.width, height: fitted.height).integral
    }

    // MARK: Playback

    @objc private func togglePlay() { isPlaying ? pause() : play() }

    private func play() {
        guard frames.count > 1, !isPlaying else { return }
        if mode == .once && current == frames.count - 1 { show(0) }
        isPlaying = true
        lastTimestamp = 0
        accumulated = 0
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 120, preferred: Float(max(fps, 30)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        playButton.setImage(UIImage(systemName: "pause.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)), for: .normal)
        playButton.accessibilityLabel = "Pause"
        UIApplication.shared.isIdleTimerDisabled = true
    }

    private func pause() {
        guard isPlaying else { return }
        isPlaying = false
        displayLink?.invalidate()
        displayLink = nil
        playButton.setImage(UIImage(systemName: "play.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)), for: .normal)
        playButton.accessibilityLabel = "Play"
        UIApplication.shared.isIdleTimerDisabled = false
    }

    @objc private func tick(_ link: CADisplayLink) {
        if lastTimestamp == 0 { lastTimestamp = link.timestamp; return }
        accumulated += link.timestamp - lastTimestamp
        lastTimestamp = link.timestamp
        let frameDuration = 1 / Double(fps)
        while accumulated >= frameDuration {
            accumulated -= frameDuration
            advance()
            if !isPlaying { return }
        }
    }

    private func advance() {
        switch mode {
        case .loop:
            show((current + 1) % frames.count)
        case .once:
            if current + 1 >= frames.count { pause() } else { show(current + 1) }
        case .pingPong:
            var next = current + direction
            if next >= frames.count || next < 0 {
                direction = -direction
                next = current + direction
            }
            show(next)
        }
    }

    private func step(_ delta: Int) {
        pause()
        show((current + delta + frames.count) % frames.count)
    }

    @objc private func nextFrame() { step(1) }
    @objc private func previousFrame() { step(-1) }
    @objc private func close() { dismiss(animated: true) }

    override var keyCommands: [UIKeyCommand]? {
        let commands = [
            UIKeyCommand(title: "Play/Pause", action: #selector(togglePlay), input: " "),
            UIKeyCommand(title: "Next Frame", action: #selector(nextFrame), input: UIKeyCommand.inputRightArrow),
            UIKeyCommand(title: "Previous Frame", action: #selector(previousFrame), input: UIKeyCommand.inputLeftArrow),
            UIKeyCommand(title: "Close", action: #selector(close), input: UIKeyCommand.inputEscape),
        ]
        commands.forEach { $0.wantsPriorityOverSystemBehavior = true }
        return commands
    }
}
