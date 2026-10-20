import Foundation

struct Bookmark: Codable, Hashable {
    let id: UUID
    var name: String
    var data: Data
    var lastOpened: Date
}

/// Remembers folders picked from Files (iCloud, USB drives, SMB shares, third-party providers)
/// using bookmarks so they can be reopened without asking again.
final class BookmarkStore {
    static let shared = BookmarkStore()

    private let defaultsKey = "bookmarks"
    private(set) var items: [Bookmark] = []

    private init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([Bookmark].self, from: data) {
            items = decoded
        }
    }

    /// `url` must be a security-scoped URL returned by the document picker.
    @discardableResult
    func add(_ url: URL) -> Bookmark? {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else {
            return nil
        }
        items.removeAll { resolve($0)?.standardizedFileURL == url.standardizedFileURL }
        let bookmark = Bookmark(id: UUID(), name: url.lastPathComponent, data: data, lastOpened: Date())
        items.insert(bookmark, at: 0)
        save()
        return bookmark
    }

    func resolve(_ bookmark: Bookmark) -> URL? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark.data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else {
            return nil
        }
        if stale, let index = items.firstIndex(of: bookmark) {
            let accessing = url.startAccessingSecurityScopedResource()
            if let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                items[index].data = fresh
                save()
            }
            if accessing { url.stopAccessingSecurityScopedResource() }
        }
        return url
    }

    func touch(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var bookmark = items.remove(at: index)
        bookmark.lastOpened = Date()
        items.insert(bookmark, at: 0)
        save()
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}

/// Keeps security-scoped access open while a folder tree is being browsed. Each window (owner)
/// keeps its own set, so switching folders in one window never cuts off another; the system
/// counts starts and stops per URL, so two windows can hold the same folder.
enum ScopedAccess {
    private static var active: [ObjectIdentifier: [URL]] = [:]

    static func begin(_ url: URL, owner: AnyObject) {
        if url.startAccessingSecurityScopedResource() {
            active[ObjectIdentifier(owner), default: []].append(url)
        }
    }

    static func endAll(owner: AnyObject) {
        active.removeValue(forKey: ObjectIdentifier(owner))?.forEach { $0.stopAccessingSecurityScopedResource() }
    }
}
