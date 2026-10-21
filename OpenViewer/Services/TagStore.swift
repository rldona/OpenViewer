import UIKit

/// Finder-style colour labels for images.
enum TagColor: String, CaseIterable, Codable {
    case red, orange, yellow, green, blue, purple, gray

    var title: String { rawValue.capitalized }

    var color: UIColor {
        switch self {
        case .red: return .systemRed
        case .orange: return .systemOrange
        case .yellow: return .systemYellow
        case .green: return .systemGreen
        case .blue: return .systemBlue
        case .purple: return .systemPurple
        case .gray: return .systemGray
        }
    }

    var dot: UIImage? {
        UIImage(systemName: "circle.fill")?.withTintColor(color, renderingMode: .alwaysOriginal)
    }
}

/// Tags per image file, keyed like favourites. Image files are never modified. Main-thread API.
final class TagStore {
    static let shared = TagStore(fileURL: FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("OpenViewer/tags.plist"))

    static let didChange = Notification.Name("OpenViewer.tagsDidChange")

    /// Path key → tag raw values.
    private var entries: [String: [String]] = [:]
    private let fileURL: URL?

    init(fileURL: URL?) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let stored = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: [String]] {
            entries = stored
        }
    }

    func tags(for url: URL) -> [TagColor] { tags(forKey: FavoritesStore.key(url)) }

    func tags(forKey key: String) -> [TagColor] {
        guard let raw = entries[key] else { return [] }
        return raw.compactMap(TagColor.init(rawValue:))
    }

    func has(_ tag: TagColor, _ url: URL) -> Bool { tags(for: url).contains(tag) }

    /// Adds or removes `tag` on every URL.
    func set(_ tag: TagColor, on urls: [URL], _ enabled: Bool) {
        for url in urls {
            let key = FavoritesStore.key(url)
            var tags = entries[key] ?? []
            if enabled {
                if !tags.contains(tag.rawValue) { tags.append(tag.rawValue) }
            } else {
                tags.removeAll { $0 == tag.rawValue }
            }
            entries[key] = tags.isEmpty ? nil : tags.sorted { a, b in
                (TagColor.allCases.firstIndex { $0.rawValue == a } ?? 0) < (TagColor.allCases.firstIndex { $0.rawValue == b } ?? 0)
            }
        }
        save()
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// Path keys of files with `tag`.
    func keys(for tag: TagColor) -> Set<String> {
        Set(entries.lazy.filter { $0.value.contains(tag.rawValue) }.map(\.key))
    }

    func urls(for tag: TagColor) -> [URL] {
        keys(for: tag).sorted().map(PathKey.url)
    }

    /// Tags in use, with how many images have each.
    var counts: [(tag: TagColor, count: Int)] {
        TagColor.allCases.compactMap { tag in
            let count = entries.values.reduce(0) { $0 + ($1.contains(tag.rawValue) ? 1 : 0) }
            return count > 0 ? (tag, count) : nil
        }
    }

    private func save() {
        guard let fileURL,
              let data = try? PropertyListSerialization.data(fromPropertyList: entries, format: .binary, options: 0) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// A saved view of a folder: its filters, kept as a shortcut in the sidebar.
struct SmartAlbum: Codable, Hashable {
    let id: UUID
    var name: String
    /// The folder, as a path key plus a bookmark for folders outside the app.
    var path: String
    var bookmark: Data?
    var includeSubfolders: Bool
    var query: String
    var minimumSide: Int
    var favoritesOnly: Bool
    var color: String?
    var tag: String?

    var colorFamily: ColorFamily? { color.flatMap(ColorFamily.init(rawValue:)) }
    var tagColor: TagColor? { tag.flatMap(TagColor.init(rawValue:)) }

    /// Human summary of the rules, e.g. "All subfolders · ≥ 256 px · Red tag".
    var summary: String {
        var parts: [String] = []
        if includeSubfolders { parts.append("All subfolders") }
        if !query.isEmpty { parts.append("“\(query)”") }
        if minimumSide > 0 { parts.append("≥ \(minimumSide) px") }
        if favoritesOnly { parts.append("Favorites") }
        if let colorFamily { parts.append(colorFamily.title) }
        if let tagColor { parts.append("\(tagColor.title) tag") }
        return parts.joined(separator: " · ")
    }
}

/// Saved smart albums, in sidebar order. Main-thread API.
final class SmartAlbumStore {
    static let shared = SmartAlbumStore(fileURL: FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("OpenViewer/smart-albums.json"))

    private(set) var items: [SmartAlbum] = []
    private let fileURL: URL?

    init(fileURL: URL?) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let stored = try? JSONDecoder().decode([SmartAlbum].self, from: data) {
            items = stored
        }
    }

    func add(_ album: SmartAlbum) {
        items.append(album)
        save()
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        save()
    }

    func reorder(_ ids: [UUID]) {
        let rank = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        items.sort { (rank[$0.id] ?? .max) < (rank[$1.id] ?? .max) }
        save()
    }

    func resolve(_ album: SmartAlbum) -> URL {
        var stale = false
        if let bookmark = album.bookmark,
           let url = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) {
            return url
        }
        return PathKey.url(album.path)
    }

    private func save() {
        guard let fileURL, let data = try? JSONEncoder().encode(items) else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
        NotificationCenter.default.post(name: FavoritesStore.didChange, object: nil)
    }
}
