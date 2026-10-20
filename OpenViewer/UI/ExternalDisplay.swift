import UIKit

/// What the external display (TV, monitor, AirPlay) shows: the image open in the viewer, full
/// screen, following the iPad's zoom. The iPad stays the remote: swipe, filmstrip, zoom.
final class ExternalDisplay {
    static let shared = ExternalDisplay()
    static let didChange = Notification.Name("OpenViewer.externalDisplayDidChange")

    /// The image to show (nil = idle screen).
    private(set) var item: ImageItem?
    /// Part of the image visible on the iPad, in unit coordinates (0…1).
    private(set) var visibleRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    /// True while an external display scene is connected.
    var isConnected: Bool { connectedCount > 0 }
    fileprivate var connectedCount = 0

    func show(_ item: ImageItem?) {
        guard item?.url != self.item?.url else { return }
        self.item = item
        visibleRect = CGRect(x: 0, y: 0, width: 1, height: 1)
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    func setVisibleRect(_ rect: CGRect) {
        let clamped = rect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !clamped.isNull, clamped != visibleRect else { return }
        visibleRect = clamped
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }
}

/// Scene delegate for the external screen (non-interactive role).
final class ExternalDisplaySceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        window.rootViewController = ExternalDisplayViewController()
        window.isHidden = false
        self.window = window
        ExternalDisplay.shared.connectedCount += 1
        NotificationCenter.default.post(name: ExternalDisplay.didChange, object: nil)
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        ExternalDisplay.shared.connectedCount = max(0, ExternalDisplay.shared.connectedCount - 1)
        NotificationCenter.default.post(name: ExternalDisplay.didChange, object: nil)
        window = nil
    }
}

/// Full-screen image on black; an idle card when nothing is open.
final class ExternalDisplayViewController: UIViewController {
    private let imageLayer = CALayer()
    private let idleLabel = UILabel()
    private var shownURL: URL?
    private var token: LoadToken?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        imageLayer.contentsGravity = .resizeAspect
        imageLayer.backgroundColor = UIColor.clear.cgColor
        view.layer.addSublayer(imageLayer)
        idleLabel.text = "OpenViewer"
        idleLabel.font = .systemFont(ofSize: 34, weight: .semibold)
        idleLabel.textColor = UIColor(white: 1, alpha: 0.35)
        idleLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(idleLabel)
        NSLayoutConstraint.activate([
            idleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            idleLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        NotificationCenter.default.addObserver(forName: ExternalDisplay.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.update()
        }
        update()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = view.bounds
        CATransaction.commit()
    }

    private func update() {
        let display = ExternalDisplay.shared
        idleLabel.isHidden = display.item != nil
        // Follow the iPad's zoom: show only the part visible there.
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.12)
        imageLayer.contentsRect = display.visibleRect
        CATransaction.commit()
        guard display.item?.url != shownURL else { return }
        shownURL = display.item?.url
        ImagePipeline.screen.cancel(token)
        guard let item = display.item else {
            imageLayer.contents = nil
            return
        }
        // Instant thumbnail first, then a decode big enough for this screen.
        for pixels in ImagePipeline.thumbnailBuckets.reversed() {
            if let thumb = ImagePipeline.thumbnails.cachedImage(for: .init(item, maxPixel: pixels)) {
                imageLayer.contents = thumb.cgImage
                break
            }
        }
        let screenPixels = Int(max(view.bounds.width, view.bounds.height) * view.traitCollection.displayScale)
        token = ImagePipeline.screen.load(.init(item, maxPixel: min(max(screenPixels * 2, 2048), 4096)), priority: .high) { [weak self] image in
            guard let self, self.shownURL == item.url, let image else { return }
            let fade = CATransition()
            fade.duration = 0.25
            self.imageLayer.add(fade, forKey: "contents")
            self.imageLayer.contents = image.cgImage
        }
    }
}
