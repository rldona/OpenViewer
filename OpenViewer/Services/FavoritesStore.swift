import Foundation

/// Favourite images, stored by path in the app's own container. Image files are never modified.
/// Main-thread API.
final class FavoritesStore {
    static let shared = FavoritesStore(fileURL: FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("OpenViewer/favorites.plist"))

    /// Posted with the changed file URL as `object`.
    static let didChange = Notification.Name("OpenViewer.favoritesDidChange")

    /// Path → date added (seconds since 1970).
    private var entries: [String: Double] = [:]
    private let fileURL: URL?

    init(fileURL: URL?) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let stored = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Double] {
            entries = stored
        }
    }

    var count: Int { entries.count }

    /// Favourite file URLs, most recently added first.
    var urls: [URL] {
        entries.sorted { $0.value > $1.value }.map { URL(fileURLWithPath: $0.key) }
    }

    func contains(_ url: URL) -> Bool {
        entries[Self.key(url)] != nil
    }

    @discardableResult
    func toggle(_ url: URL) -> Bool {
        let isFavorite = !contains(url)
        set(url, favorite: isFavorite)
        return isFavorite
    }

    func set(_ url: URL, favorite: Bool) {
        let key = Self.key(url)
        guard (entries[key] != nil) != favorite else { return }
        entries[key] = favorite ? Date().timeIntervalSince1970 : nil
        save()
        NotificationCenter.default.post(name: Self.didChange, object: url)
    }

    /// The same file can surface as `/private/var/…` or `/var/…` depending on how its folder was opened.
    static func key(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        return path.hasPrefix("/private/var/") ? String(path.dropFirst("/private".count)) : path
    }

    private func save() {
        guard let fileURL,
              let data = try? PropertyListSerialization.data(fromPropertyList: entries, format: .binary, options: 0) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}

struct FavoriteFolder: Codable, Hashable {
    let id: UUID
    var name: String
    var path: String
    /// Bookmark created while the folder was reachable; lets it reopen without its parent.
    var bookmark: Data?
    var added: Date
}

/// Favourite folders shown as shortcuts on the start screen. Main-thread API.
final class FavoriteFoldersStore {
    static let shared = FavoriteFoldersStore(fileURL: FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("OpenViewer/favorite-folders.json"))

    private(set) var items: [FavoriteFolder] = []
    private let fileURL: URL?

    init(fileURL: URL?) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let stored = try? JSONDecoder().decode([FavoriteFolder].self, from: data) {
            items = stored
        }
    }

    func contains(_ url: URL) -> Bool {
        let key = FavoritesStore.key(url)
        return items.contains { $0.path == key }
    }

    @discardableResult
    func toggle(_ url: URL) -> Bool {
        let isFavorite = !contains(url)
        set(url, favorite: isFavorite)
        return isFavorite
    }

    func set(_ url: URL, favorite: Bool) {
        let key = FavoritesStore.key(url)
        guard items.contains(where: { $0.path == key }) != favorite else { return }
        if favorite {
            let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            items.insert(FavoriteFolder(id: UUID(), name: url.lastPathComponent, path: key, bookmark: bookmark, added: Date()), at: 0)
        } else {
            items.removeAll { $0.path == key }
        }
        save()
        NotificationCenter.default.post(name: FavoritesStore.didChange, object: url)
    }

    func remove(_ id: UUID) {
        guard let folder = items.first(where: { $0.id == id }) else { return }
        set(URL(fileURLWithPath: folder.path), favorite: false)
    }

    /// The folder's URL, preferring its own bookmark so it survives being reached through a different path.
    func resolve(_ folder: FavoriteFolder) -> URL {
        var stale = false
        if let bookmark = folder.bookmark,
           let url = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) {
            return url
        }
        return URL(fileURLWithPath: folder.path, isDirectory: true)
    }

    private func save() {
        guard let fileURL, let data = try? JSONEncoder().encode(items) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
