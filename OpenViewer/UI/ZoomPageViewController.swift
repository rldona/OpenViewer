import ImageIO
import UIKit

/// One page of the viewer: a zoomable image that starts from the cached thumbnail, upgrades to a
/// screen-sized decode and, when zoomed in, to a high-resolution decode.
final class ZoomPageViewController: UIViewController, UIScrollViewDelegate {
    let item: ImageItem
    let index: Int
    var onSingleTap: (() -> Void)?

    private let scrollView = UIScrollView()
    private let imageView = UIImageView()
    private var token: LoadToken?
    private var lastBoundsSize: CGSize = .zero
    private var originalPixelSize: CGSize?
    private var hiResRequested = false
    private var animationStopped = true
    /// Pixel inspector: grid at high zoom, and a long press reads the colour under the finger.
    private let pixelGrid = PixelGridView()
    private let readout = PixelReadoutView()
    private let marker = UIView()
    private lazy var sampler = PixelSampler(url: item.url)
    /// Shown by the viewer when a colour is copied.
    var onMessage: ((String) -> Void)?

    static var screenPixels: Int {
        let bounds = UIScreen.main.nativeBounds
        return Int(max(bounds.width, bounds.height))
    }

    init(item: ImageItem, index: Int) {
        self.item = item
        self.index = index
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit { ImagePipeline.screen.cancel(token) }

    var displayedImage: UIImage? { imageView.image }

    var isZoomed: Bool { scrollView.zoomScale > scrollView.minimumZoomScale + 0.01 }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        scrollView.frame = view.bounds
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.delegate = self
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.decelerationRate = .fast
        scrollView.bouncesZoom = true
        view.addSubview(scrollView)

        imageView.contentMode = .scaleAspectFit
        // The image view is sized exactly to the image, so this only shows through transparent pixels.
        imageView.backgroundColor = Settings.transparencyBackground.color
        NotificationCenter.default.addObserver(forName: TransparencyBackground.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.imageView.backgroundColor = Settings.transparencyBackground.color
        }
        imageView.isAccessibilityElement = true
        imageView.accessibilityLabel = item.name
        imageView.accessibilityTraits = .image
        scrollView.addSubview(imageView)

        pixelGrid.frame = view.bounds
        pixelGrid.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(pixelGrid)
        marker.isUserInteractionEnabled = false
        marker.layer.borderColor = UIColor.white.cgColor
        marker.layer.borderWidth = 2
        marker.layer.shadowColor = UIColor.black.cgColor
        marker.layer.shadowOpacity = 0.8
        marker.layer.shadowRadius = 2
        marker.layer.shadowOffset = .zero
        marker.isHidden = true
        view.addSubview(marker)
        readout.isHidden = true
        readout.translatesAutoresizingMaskIntoConstraints = true
        readout.onCopy = { [weak self] hex in self?.onMessage?("Copied \(hex)") }
        view.addSubview(readout)
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleInspect(_:)))
        longPress.minimumPressDuration = 0.35
        scrollView.addGestureRecognizer(longPress)

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
        let singleTap = UITapGestureRecognizer(target: self, action: #selector(handleSingleTap))
        singleTap.require(toFail: doubleTap)
        scrollView.addGestureRecognizer(singleTap)

        loadImage()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if scrollView.bounds.size != lastBoundsSize {
            lastBoundsSize = scrollView.bounds.size
            layoutImage()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startAnimationIfNeeded()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        animationStopped = true
        hideInspector()
        if isZoomed { scrollView.setZoomScale(scrollView.minimumZoomScale, animated: false) }
    }

    // MARK: Loading

    private func loadImage() {
        // 1. Instant: whatever grid thumbnail is already in memory.
        for pixels in ImagePipeline.thumbnailBuckets.reversed() {
            if let thumb = ImagePipeline.thumbnails.cachedImage(for: .init(item, maxPixel: pixels)) {
                setImage(thumb)
                break
            }
        }
        // 2. Screen-sized decode.
        token = ImagePipeline.screen.load(.init(item, maxPixel: Self.screenPixels), priority: .veryHigh) { [weak self] image in
            guard let self else { return }
            self.token = nil
            if let image {
                self.setImage(image)
            } else if self.imageView.image == nil {
                self.showError()
            }
        }
    }

    private func setImage(_ image: UIImage) {
        let previous = imageView.image?.size
        imageView.image = image
        let sameAspect = previous.map { abs($0.width / max($0.height, 1) - image.size.width / max(image.size.height, 1)) < 0.01 } ?? false
        if !sameAspect { layoutImage() }
    }

    private func showError() {
        let label = UILabel()
        label.text = "Can't open “\(item.name)”"
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.frame = view.bounds
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(label)
    }

    /// Decodes at a higher resolution once the user zooms past the screen-sized image.
    private func loadHighResolutionIfNeeded() {
        guard !hiResRequested, let image = imageView.image else { return }
        let displayedPixels = imageView.frame.width * view.traitCollection.displayScale
        guard displayedPixels > image.size.width * 1.2 else { return }
        hiResRequested = true
        let url = item.url
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let original = self?.originalPixelSize ?? ImagePipeline.pixelSize(of: url) ?? .zero
            let target = Int(min(max(original.width, original.height), 8192))
            guard target > Int(max(image.size.width, image.size.height)),
                  let cg = ImagePipeline.downsample(url, maxPixel: target) else { return }
            let hiRes = UIImage(cgImage: cg)
            DispatchQueue.main.async {
                guard let self, self.viewIfLoaded?.window != nil else { return }
                self.imageView.image = hiRes
                self.updatePixelGrid()
            }
        }
    }

    private func startAnimationIfNeeded() {
        let ext = item.url.pathExtension.lowercased()
        guard ["gif", "webp", "png", "apng", "heics"].contains(ext) else { return }
        let url = item.url
        animationStopped = false
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 1 else { return }
            DispatchQueue.main.async {
                guard let self, !self.animationStopped else { return }
                CGAnimateImageAtURLWithBlock(url as CFURL, nil) { [weak self] _, frame, stop in
                    guard let self, !self.animationStopped else { stop.pointee = true; return }
                    self.imageView.image = UIImage(cgImage: frame)
                }
            }
        }
    }

    // MARK: Layout & zoom

    private func layoutImage() {
        guard let image = imageView.image, image.size.width > 0, image.size.height > 0 else { return }
        let bounds = scrollView.bounds.size
        guard bounds.width > 0, bounds.height > 0 else { return }

        scrollView.minimumZoomScale = 1
        scrollView.zoomScale = 1
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let fitted = CGSize(width: (image.size.width * scale).rounded(), height: (image.size.height * scale).rounded())
        imageView.frame = CGRect(origin: .zero, size: fitted)
        scrollView.contentSize = fitted

        // Allow zooming to at least 2× the native resolution of the original file.
        let url = item.url
        if originalPixelSize == nil {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let size = ImagePipeline.pixelSize(of: url)
                DispatchQueue.main.async {
                    self?.originalPixelSize = size
                    self?.updateMaximumZoom()
                    self?.updatePixelGrid()
                }
            }
        }
        updateMaximumZoom()
        centerContent()
        updatePixelGrid()
    }

    private func updateMaximumZoom() {
        let fittedPixels = imageView.bounds.width * view.traitCollection.displayScale
        let originalWidth = originalPixelSize?.width ?? fittedPixels
        let native = fittedPixels > 0 ? originalWidth / fittedPixels : 1
        scrollView.maximumZoomScale = min(max(4, native * 2), 32)
    }

    private func centerContent() {
        let bounds = scrollView.bounds.size
        let content = scrollView.contentSize
        let insetX = max(0, (bounds.width - content.width) / 2)
        let insetY = max(0, (bounds.height - content.height) / 2)
        scrollView.contentInset = UIEdgeInsets(top: insetY, left: insetX, bottom: insetY, right: insetX)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerContent()
        updatePixelGrid()
        mirrorVisibleRect()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updatePixelGrid()
        mirrorVisibleRect()
    }

    /// The external display follows this page's zoom while it is the one on screen.
    private func mirrorVisibleRect() {
        guard ExternalDisplay.shared.isConnected, ExternalDisplay.shared.item?.url == item.url,
              imageView.bounds.width > 0 else { return }
        let visible = view.convert(view.bounds, to: imageView)
        ExternalDisplay.shared.setVisibleRect(CGRect(x: visible.minX / imageView.bounds.width,
                                                     y: visible.minY / imageView.bounds.height,
                                                     width: visible.width / imageView.bounds.width,
                                                     height: visible.height / imageView.bounds.height))
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        loadHighResolutionIfNeeded()
    }

    @objc private func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
        if isZoomed {
            scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
            return
        }
        let point = gesture.location(in: imageView)
        let scale = min(scrollView.maximumZoomScale, 2.5)
        let size = CGSize(width: scrollView.bounds.width / scale, height: scrollView.bounds.height / scale)
        scrollView.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                   width: size.width, height: size.height), animated: true)
    }

    @objc private func handleSingleTap() {
        if !readout.isHidden {
            hideInspector()
            return
        }
        onSingleTap?()
    }

    // MARK: Pixel inspector

    /// Keeps the pixel grid on the image and switches to hard-edged pixels once they are clearly visible.
    private func updatePixelGrid() {
        guard isViewLoaded else { return }
        let size = originalPixelSize ?? .zero
        pixelGrid.pixelSize = size
        pixelGrid.imageFrame = imageView.convert(imageView.bounds, to: view)
        let screenPixelsPerImagePixel = pixelGrid.pointsPerPixel * view.traitCollection.displayScale
        imageView.layer.magnificationFilter = screenPixelsPerImagePixel >= 3 ? .nearest : .linear
        if !marker.isHidden, let sample = readout.sample { placeMarker(on: sample) }
    }

    @objc private func handleInspect(_ press: UILongPressGestureRecognizer) {
        switch press.state {
        case .began:
            UISelectionFeedbackGenerator().selectionChanged()
            sampler.prepare { [weak self, weak press] in
                guard let self, let press else { return }
                self.inspect(at: press.location(in: self.view))
            }
            inspect(at: press.location(in: view))
        case .changed:
            inspect(at: press.location(in: view))
        default:
            break
        }
    }

    private func inspect(at point: CGPoint) {
        let frame = imageView.convert(imageView.bounds, to: view)
        guard frame.width > 0, frame.height > 0 else { return }
        let unit = CGPoint(x: (point.x - frame.minX) / frame.width, y: (point.y - frame.minY) / frame.height)
        guard let sample = sampler.sample(atUnit: unit) else { return }
        if readout.sample != sample { readout.show(sample) }
        readout.isHidden = false
        marker.isHidden = false
        placeMarker(on: sample)
        // Above the finger, kept on screen.
        let size = readout.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        var origin = CGPoint(x: point.x - size.width / 2, y: point.y - size.height - 70)
        if origin.y < view.safeAreaInsets.top + 70 { origin.y = point.y + 70 }
        origin.x = min(max(origin.x, 12), view.bounds.width - size.width - 12)
        readout.frame = CGRect(origin: origin, size: size)
    }

    /// Outlines the sampled pixel, or rings the spot when pixels are too small to outline.
    private func placeMarker(on sample: PixelSampler.Sample) {
        let frame = imageView.convert(imageView.bounds, to: view)
        let size = sampler.pixelSize
        guard size.width > 0 else { return }
        let step = frame.width / size.width
        let center = CGPoint(x: frame.minX + (CGFloat(sample.x) + 0.5) * step, y: frame.minY + (CGFloat(sample.y) + 0.5) * step)
        let side = max(step, 14)
        marker.frame = CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
        marker.layer.cornerRadius = step >= 14 ? 0 : side / 2
    }

    private func hideInspector() {
        readout.isHidden = true
        marker.isHidden = true
    }

    func resetZoom() {
        scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
    }
}
