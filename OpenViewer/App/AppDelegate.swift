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
        UISceneConfiguration(name: "Default", sessionRole: connectingSceneSession.role)
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

final class RootSplitViewController: UISplitViewController {
    override var prefersStatusBarHidden: Bool { true }
    override var childForStatusBarHidden: UIViewController? { nil }
}
