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
            entries = Dictionary(stored.map { (PathKey.migrate($0.key), $0.value) }, uniquingKeysWith: max)
            if entries.keys.sorted() != stored.keys.sorted() { save() }
        }
    }

    var count: Int { entries.count }

    /// Favourite file URLs, most recently added first.
    var urls: [URL] {
        entries.sorted { $0.value > $1.value }.map { PathKey.url($0.key) }
    }

    func contains(_ url: URL) -> Bool {
        entries[Self.key(url)] != nil
    }

    /// Snapshot of all keys, for filtering large lists off the main thread with `key(path:)`.
    var keys: Set<String> { Set(entries.keys) }

    @discardableResult
    func toggle(_ url: URL) -> Bool {
        let isFavorite = !contains(url)
        set(url, favorite: isFavorite)
        return isFavorite
    }

    /// Bulk change with a single save and notification.
    func set(_ urls: [URL], favorite: Bool) {
        let now = Date().timeIntervalSince1970
        for url in urls { entries[Self.key(url)] = favorite ? now : nil }
        save()
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// Keeps favourites attached to files that were moved or renamed by the app.
    func move(from old: URL, to new: URL) {
        guard let added = entries.removeValue(forKey: Self.key(old)) else { return }
        entries[Self.key(new)] = added
        save()
    }

    func set(_ url: URL, favorite: Bool) {
        let key = Self.key(url)
        guard (entries[key] != nil) != favorite else { return }
        entries[key] = favorite ? Date().timeIntervalSince1970 : nil
        save()
        NotificationCenter.default.post(name: Self.didChange, object: url)
    }

    static func key(_ url: URL) -> String {
        key(path: url.standardizedFileURL.path)
    }

    /// Cheap variant for paths that are already standardized (e.g. from a directory enumerator).
    static func key(path: String) -> String {
        PathKey.make(path)
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
            items = stored.map { var folder = $0; folder.path = PathKey.migrate(folder.path); return folder }
            if items != stored { save() }
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
        set(PathKey.url(folder.path), favorite: false)
    }

    /// The folder's URL, preferring its own bookmark so it survives being reached through a different path.
    func resolve(_ folder: FavoriteFolder) -> URL {
        var stale = false
        if let bookmark = folder.bookmark,
           let url = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) {
            return url
        }
        return PathKey.url(folder.path)
    }

    private func save() {
        guard let fileURL, let data = try? JSONEncoder().encode(items) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}
