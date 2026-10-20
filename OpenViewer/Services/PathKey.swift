import Foundation

/// Stable string keys for files, used by favourites and caches.
///
/// iOS moves the app's own container (`…/Containers/Data/Application/<UUID>/`) on every reinstall
/// or update, so files inside it are keyed relative to it (`~/Documents/…`). Paths elsewhere
/// (iCloud Drive, other apps' storage, external drives) are kept as they are.
enum PathKey {
    private static let home = stripPrivate(NSHomeDirectory())
    private static let containerPattern = try! NSRegularExpression(
        pattern: "^(/private)?/.*?/Containers/Data/Application/[0-9A-Fa-f-]{36}(?=/|$)")

    static func make(_ path: String) -> String {
        let path = stripPrivate(path)
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    static func url(_ key: String) -> URL {
        if key == "~" { return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true) }
        if key.hasPrefix("~/") { return URL(fileURLWithPath: NSHomeDirectory() + key.dropFirst()) }
        return URL(fileURLWithPath: key)
    }

    /// Rewrites keys saved by earlier versions with an absolute path into an old app container.
    static func migrate(_ key: String) -> String {
        guard !key.hasPrefix("~") else { return key }
        let range = NSRange(key.startIndex..., in: key)
        guard let match = containerPattern.firstMatch(in: key, range: range),
              let matched = Range(match.range, in: key) else { return make(key) }
        return "~" + key[matched.upperBound...]
    }

    /// The same file can surface as `/private/var/…` or `/var/…` depending on how it was reached.
    private static func stripPrivate(_ path: String) -> String {
        path.hasPrefix("/private/var/") ? String(path.dropFirst("/private".count)) : path
    }
}
