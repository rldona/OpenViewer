import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        ImagePipeline.removeLegacyCaches()
        return true
    }

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        // A TV or monitor without Stage Manager shows the open image full screen.
        connectingSceneSession.role == .windowExternalDisplayNonInteractive
            ? UISceneConfiguration(name: "External Display", sessionRole: connectingSceneSession.role)
            : UISceneConfiguration(name: "Default", sessionRole: connectingSceneSession.role)
    }

    func applicationDidReceiveMemoryWarning(_ application: UIApplication) {
        ImagePipeline.screen.clearMemory()
        ImagePipeline.thumbnails.clearMemory()
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)

        // Regular width: sidebar beside the folder being browsed.
        let detail = RootNavigationController()
        let empty = EmptyLibraryViewController()
        detail.setViewControllers([empty], animated: false)
        let sidebar = SidebarViewController(detailNavigation: detail)
        empty.onOpenFolder = { [weak sidebar] in sidebar?.pickFolder() }
        let sidebarNavigation = UINavigationController(rootViewController: sidebar)
        sidebarNavigation.navigationBar.prefersLargeTitles = true

        // Compact width (Slide Over, narrow split screen): the library is the root and pushes folders.
        let compact = RootNavigationController(rootViewController: SidebarViewController(detailNavigation: nil))
        compact.navigationBar.prefersLargeTitles = true

        let split = RootSplitViewController(style: .doubleColumn)
        split.preferredDisplayMode = .automatic
        split.preferredSplitBehavior = .tile
        split.primaryBackgroundStyle = .sidebar
        split.minimumPrimaryColumnWidth = 260
        split.maximumPrimaryColumnWidth = 320
        split.setViewController(sidebarNavigation, for: .primary)
        split.setViewController(detail, for: .secondary)
        split.setViewController(compact, for: .compact)
        window.rootViewController = split
        // Fill the detail column before the first frame, so launch doesn't flash the "Open a folder" screen.
        // A window opened with "Open in New Window" starts in its folder.
        if let url = connectionOptions.userActivities.lazy.compactMap(WindowOpener.folder(from:)).first {
            sidebar.openFolder(url)
            windowScene.title = url.lastPathComponent
        } else {
            sidebar.restoreLastFolderBeforeLaunch()
        }
        window.tintColor = Theme.accent
        window.overrideUserInterfaceStyle = Appearance.current.style
        window.makeKeyAndVisible()
        self.window = window
    }
}

/// The app hides the status bar everywhere so images get the whole screen.
final class RootNavigationController: UINavigationController {
    override var prefersStatusBarHidden: Bool { true }
    override var childForStatusBarHidden: UIViewController? { nil }
}

final class RootSplitViewController: UISplitViewController, UISplitViewControllerDelegate {
    /// Posted after the sidebar is shown or hidden (it floats over the content, which isn't resized).
    static let sidebarDidChange = Notification.Name("OpenViewer.sidebarDidChange")

    override var prefersStatusBarHidden: Bool { true }
    override var childForStatusBarHidden: UIViewController? { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        delegate = self
    }

    func splitViewController(_ svc: UISplitViewController, willChangeTo displayMode: UISplitViewController.DisplayMode) {
        let post = { NotificationCenter.default.post(name: Self.sidebarDidChange, object: svc) }
        if let coordinator = svc.transitionCoordinator {
            coordinator.animate(alongsideTransition: nil) { _ in post() }
        } else {
            DispatchQueue.main.async(execute: post)
        }
    }
}

/// Opens a folder in a new window (Stage Manager, Split View).
enum WindowOpener {
    static let activityType = "io.github.rldona.OpenViewer.openFolder"
    private static let bookmarkKey = "bookmark"

    static func open(_ url: URL) {
        let activity = NSUserActivity(activityType: activityType)
        guard let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else { return }
        activity.userInfo = [bookmarkKey: bookmark]
        activity.title = url.lastPathComponent
        let request = UISceneSessionActivationRequest(role: .windowApplication, userActivity: activity)
        UIApplication.shared.activateSceneSession(for: request) { error in
            print("Open in New Window failed: \(error)")
        }
    }

    static func folder(from activity: NSUserActivity) -> URL? {
        guard activity.activityType == activityType, let data = activity.userInfo?[bookmarkKey] as? Data else { return nil }
        var stale = false
        return try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
    }
}
