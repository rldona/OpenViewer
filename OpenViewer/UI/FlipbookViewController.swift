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

/// Frames stored inside one file: animated GIF, APNG, WebP or HEIC sequence.
enum AnimatedImage {
    private static let extensions: Set<String> = ["gif", "png", "apng", "webp", "heics", "heic", "avif"]

    /// Number of frames (1 for a still image). Reads the file's structure, not its pixels.
    static func frameCount(of url: URL) -> Int {
        guard extensions.contains(url.pathExtension.lowercased()),
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return 1 }
        return CGImageSourceGetCount(source)
    }

    /// How long each frame stays on screen, in seconds. Like browsers, delays under 11 ms (often
    /// written as 0 by encoders) are treated as 100 ms.
    static func delays(of source: CGImageSource) -> [Double] {
        let dictionaries: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
            (kCGImagePropertyHEICSDictionary, kCGImagePropertyHEICSUnclampedDelayTime, kCGImagePropertyHEICSDelayTime),
        ]
        return (0..<CGImageSourceGetCount(source)).map { index in
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
            for (dictionary, unclamped, clamped) in dictionaries {
                guard let values = properties[dictionary] as? [CFString: Any] else { continue }
                let delay = (values[unclamped] as? Double) ?? (values[clamped] as? Double) ?? 0
                return delay < 0.011 ? 0.1 : delay
            }
            return 0.1
        }
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
    /// Set when playing the frames inside one animated file instead of a list of files.
    private let animatedFile: ImageItem?
    private let frameCount: Int
    /// Each frame's own duration in an animated file; empty for a list of files.
    private var delays: [Double] = []
    /// Plays an animated file at its own timing instead of a fixed frame rate.
    private var usesOriginalTiming = false
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
        animatedFile = nil
        frameCount = frames.count
        images = Array(repeating: nil, count: frames.count)
        pixelSizes = Array(repeating: .zero, count: frames.count)
        current = min(max(index, 0), max(frames.count - 1, 0))
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
        overrideUserInterfaceStyle = .dark
    }

    /// The frames of an animated GIF, APNG, WebP or HEIC sequence, played at their own timing.
    init(animatedFile item: ImageItem, frameCount: Int) {
        frames = []
        animatedFile = item
        self.frameCount = frameCount
        usesOriginalTiming = true
        images = Array(repeating: nil, count: frameCount)
        pixelSizes = Array(repeating: .zero, count: frameCount)
        current = 0
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
        scrubber.maximumValue = Float(max(frameCount - 1, 1))
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
        speedButton.configuration?.title = usesOriginalTiming ? "Original" : "\(fps) fps"
        var speeds: [UIMenuElement] = Self.speeds.map { value in
            UIAction(title: "\(value) fps", state: !usesOriginalTiming && value == fps ? .on : .off) { [weak self] _ in
                self?.usesOriginalTiming = false
                self?.fps = value
                UserDefaults.standard.set(value, forKey: "flipbookFPS")
                self?.updateMenus()
            }
        }
        if animatedFile != nil {
            // The file's own timing, which can differ frame by frame.
            let average = delays.isEmpty ? 0 : delays.reduce(0, +) / Double(delays.count)
            let subtitle = average > 0 ? "≈ \(Int((1 / average).rounded())) fps, as saved in the file" : "As saved in the file"
            speeds.insert(UIMenu(options: .displayInline, children: [
                UIAction(title: "Original", subtitle: subtitle, state: usesOriginalTiming ? .on : .off) { [weak self] _ in
                    self?.usesOriginalTiming = true
                    self?.updateMenus()
                },
            ]), at: 0)
        }
        speedButton.menu = UIMenu(title: "Speed", children: speeds)
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
        if let animatedFile {
            loadAnimatedFrames(animatedFile)
            return
        }
        let frames = self.frames
        progress.isHidden = frameCount < 2
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

    /// Frames of one animated file. They are decoded in order: formats like GIF build each frame on
    /// top of the previous one, and ImageIO hands them back already composed (whole frames).
    private func loadAnimatedFrames(_ item: ImageItem) {
        let count = frameCount
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let source = CGImageSourceCreateWithURL(item.url as CFURL, nil) else { return }
            let delays = AnimatedImage.delays(of: source)
            let size = ImagePipeline.pixelSize(of: item.url) ?? .zero
            let perFrame = Double(Self.memoryBudget) / Double(max(count, 1)) / 4
            let maxSide = CGFloat(max(64, min(ZoomPageViewController.screenPixels, Int(perFrame.squareRoot()))))
            let largest = max(size.width, size.height)
            let scale = largest > maxSide ? maxSide / largest : 1
            DispatchQueue.main.async {
                guard let self else { return }
                self.delays = delays
                self.pixelSizes = Array(repeating: size, count: count)
                self.updateMenus()
                self.layoutFrame()
            }
            for index in 0..<count {
                guard let self, !self.cancelled else { return }
                var image = CGImageSourceCreateImageAtIndex(source, index, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
                    .map { UIImage(cgImage: $0) }
                if scale < 1, let full = image {
                    // Very long or very large animations are scaled down to stay within the memory budget.
                    let target = CGSize(width: (full.size.width * scale).rounded(), height: (full.size.height * scale).rounded())
                    let format = UIGraphicsImageRendererFormat()
                    format.scale = 1
                    image = UIGraphicsImageRenderer(size: target, format: format).image { _ in full.draw(in: CGRect(origin: .zero, size: target)) }
                }
                DispatchQueue.main.async {
                    self.images[index] = image
                    self.loadedCount += 1
                    self.progress.setProgress(Float(self.loadedCount) / Float(count), animated: false)
                    if self.loadedCount == count { UIView.animate(withDuration: 0.3) { self.progress.alpha = 0 } }
                    if index == self.current { self.show(index) }
                }
            }
        }
    }

    private func show(_ index: Int) {
        guard (0..<frameCount).contains(index) else { return }
        current = index
        if let image = images[index] {
            imageView.image = image
        } else if imageView.image == nil {
            let item = animatedFile ?? frames[index]
            imageView.image = ImagePipeline.thumbnails.cachedImage(for: .init(item, maxPixel: 512))
        }
        titleLabel.text = animatedFile?.name ?? frames[index].name
        counterLabel.text = "\(index + 1) / \(frameCount)"
        if !scrubber.isTracking { scrubber.value = Float(index) }
        layoutFrame()
    }

    /// Every frame uses one scale (fitting the largest), so differently sized frames keep their proportions.
    private func layoutFrame() {
        let bounds = canvas.bounds.inset(by: UIEdgeInsets(top: 72, left: 16, bottom: 96, right: 16))
        guard bounds.width > 0, pixelSizes.indices.contains(current) else { return }
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
        guard frameCount > 1, !isPlaying else { return }
        if mode == .once && current == frameCount - 1 { show(0) }
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
        while accumulated >= currentFrameDuration {
            accumulated -= currentFrameDuration
            advance()
            if !isPlaying { return }
        }
    }

    private var currentFrameDuration: Double {
        if usesOriginalTiming, delays.indices.contains(current) { return delays[current] }
        return 1 / Double(fps)
    }

    private func advance() {
        switch mode {
        case .loop:
            show((current + 1) % frameCount)
        case .once:
            if current + 1 >= frameCount { pause() } else { show(current + 1) }
        case .pingPong:
            var next = current + direction
            if next >= frameCount || next < 0 {
                direction = -direction
                next = current + direction
            }
            show(next)
        }
    }

    private func step(_ delta: Int) {
        pause()
        show((current + delta + frameCount) % frameCount)
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
