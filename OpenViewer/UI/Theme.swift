import UIKit

/// The app's look: a dark gallery where the art is the colour, plus one warm accent.
enum Theme {
    /// Warm amber, readable on the dark ground (and on light grounds when following the system).
    static let accent = UIColor(red: 0.96, green: 0.71, blue: 0.27, alpha: 1)
    /// Dark text for use on top of the accent.
    static let onAccent = UIColor(red: 0.10, green: 0.07, blue: 0.02, alpha: 1)
    /// Near-black ground in dark mode, the system background otherwise.
    static let background = UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 0.043, alpha: 1) : .systemBackground
    }
    static let sidebarBackground = UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 0.075, alpha: 1) : .systemGroupedBackground
    }
}

/// App-wide appearance preference: dark by default, which suits browsing artwork.
enum Appearance: String, CaseIterable {
    case dark, system

    var title: String { self == .dark ? "Dark" : "Match System" }
    var style: UIUserInterfaceStyle { self == .dark ? .dark : .unspecified }

    static var current: Appearance {
        get { Appearance(rawValue: UserDefaults.standard.string(forKey: "appearance") ?? "") ?? .dark }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "appearance")
            for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
                scene.windows.forEach { $0.overrideUserInterfaceStyle = newValue.style }
            }
        }
    }
}

/// A floating capsule or rounded panel of glass for controls drawn over content.
/// The effect is applied only to these few bars, never per thumbnail, so its cost stays constant.
class GlassView: UIVisualEffectView {
    private let capsule: Bool
    private let radius: CGFloat

    /// `cornerRadius` nil = capsule (fully rounded ends).
    init(cornerRadius: CGFloat? = nil) {
        capsule = cornerRadius == nil
        radius = cornerRadius ?? 0
        let effect: UIVisualEffect
        if #available(iOS 26.0, *) {
            effect = UIGlassEffect()
        } else {
            effect = UIBlurEffect(style: .systemUltraThinMaterialDark)
        }
        super.init(effect: effect)
        layer.cornerCurve = .continuous
        clipsToBounds = true
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = capsule ? bounds.height / 2 : radius
    }

    /// Pins `content` inside with the given padding.
    func embed(_ content: UIView, insets: NSDirectionalEdgeInsets) {
        content.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: contentView.topAnchor, constant: insets.top),
            content.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -insets.bottom),
            content.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: insets.leading),
            content.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -insets.trailing),
        ])
    }
}

extension UIViewController {
    /// The part of the view not covered by bars or the floating sidebar, in the view's coordinates.
    /// On iPadOS 26 the sidebar floats over the detail column, so the view's bounds still run under it.
    var areaClearOfSidebar: CGRect {
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

    /// Calls `update` whenever the sidebar is shown or hidden, and once more after it settles.
    func observeSidebarChanges(_ update: @escaping () -> Void) {
        NotificationCenter.default.addObserver(forName: RootSplitViewController.sidebarDidChange, object: nil, queue: .main) { _ in
            update()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { update() }
        }
    }
}
