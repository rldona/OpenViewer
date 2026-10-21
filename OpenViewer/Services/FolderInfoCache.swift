import Foundation

/// Lazily computed summary (counts + cover image) for folder cells. Main-thread API.
final class FolderInfoCache {
    struct Info: Equatable {
        let imageCount: Int
        let folderCount: Int
        /// Up to four images for the folder's mosaic, the first being the main cover.
        let covers: [ImageItem]
        var cover: ImageItem? { covers.first }
        /// Whether any image exists anywhere below this folder.
        let containsImages: Bool

        var subtitle: String {
            var parts: [String] = []
            if imageCount > 0 { parts.append("\(imageCount.formatted()) image\(imageCount == 1 ? "" : "s")") }
            if folderCount > 0 { parts.append("\(folderCount.formatted()) folder\(folderCount == 1 ? "" : "s")") }
            return parts.isEmpty ? "Empty" : parts.joined(separator: " · ")
        }
    }

    static let shared = FolderInfoCache(fileURL: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appendingPathComponent("OpenViewer/folder-info.bin"))

    private var cache: [URL: Info] = [:]
    private var pending: [URL: [(Info) -> Void]] = [:]
    /// Summaries from earlier sessions, by path key, with the folder's modification date then.
    private var stored: [String: (modified: Double, info: Info)]?
    /// After a refresh or a file operation, stored summaries are shown but always recomputed.
    private var trustsStored = true
    private var saveScheduled = false
    private let fileURL: URL?
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 4
        queue.qualityOfService = .userInitiated
        return queue
    }()

    init(fileURL: URL?) {
        self.fileURL = fileURL
    }

    func cached(_ url: URL) -> Info? { cache[url] }

    /// Calls back at once with what is known (from memory, or from disk when the folder looks
    /// unchanged), and again only if a fresh look at the folder finds something different.
    func info(for url: URL, modified: Date? = nil, completion: @escaping (Info) -> Void) {
        if let info = cache[url] { completion(info); return }
        if pending[url] != nil { pending[url]?.append(completion); return }
        let key = FavoritesStore.key(url)
        if let entry = storedEntries[key] {
            cache[url] = entry.info
            completion(entry.info)
            let unchanged = modified.map { abs($0.timeIntervalSince1970 - entry.modified) < 0.001 } ?? false
            if trustsStored && unchanged { return }
            // Shown already; refresh quietly and only call back again if it changed.
            pending[url] = [{ info in if info != entry.info { completion(info) } }]
        } else {
            pending[url] = [completion]
        }
        queue.addOperation { [weak self] in
            let info = Self.compute(url)
            let folderModified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate?.timeIntervalSince1970 ?? 0
            DispatchQueue.main.async {
                guard let self else { return }
                self.cache[url] = info
                _ = self.storedEntries
                self.stored![key] = (folderModified, info)
                self.scheduleSave()
                self.pending.removeValue(forKey: url)?.forEach { $0(info) }
            }
        }
    }

    func invalidate() {
        cache.removeAll()
        trustsStored = false
    }

    // MARK: Persistence

    /// Read on first use. Writes go to `stored!` directly: through this getter they'd copy it all.
    private var storedEntries: [String: (modified: Double, info: Info)] {
        if stored == nil { stored = fileURL.flatMap { try? Data(contentsOf: $0) }.flatMap(Self.decode) ?? [:] }
        return stored!
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, let fileURL = self.fileURL, let entries = self.stored else { return }
            self.saveScheduled = false
            DispatchQueue.global(qos: .utility).async {
                try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? Self.encode(entries).write(to: fileURL, options: .atomic)
            }
        }
    }

    private static let magic = "OVFI"

    static func encode(_ entries: [String: (modified: Double, info: Info)]) -> Data {
        var writer = BinaryWriter(magic: magic, version: 1)
        writer.writeCount(entries.count)
        for (key, entry) in entries {
            writer.write(key)
            writer.write(entry.modified)
            writer.write(Int64(entry.info.imageCount))
            writer.write(Int64(entry.info.folderCount))
            writer.write(UInt8(entry.info.containsImages ? 1 : 0))
            writer.writeCount(entry.info.covers.count)
            for cover in entry.info.covers {
                writer.write(FavoritesStore.key(cover.url))
                writer.write(Int64(cover.size))
                writer.write(cover.modified.timeIntervalSince1970)
            }
        }
        return writer.data
    }

    static func decode(_ data: Data) -> [String: (modified: Double, info: Info)]? {
        guard var reader = BinaryReader(data: data, magic: magic, version: 1) else { return nil }
        let count = reader.readCount()
        var entries: [String: (modified: Double, info: Info)] = [:]
        entries.reserveCapacity(count)
        for _ in 0..<count {
            let key = reader.readString()
            let modified = reader.readDouble()
            let imageCount = Int(reader.read(Int64.self))
            let folderCount = Int(reader.read(Int64.self))
            let containsImages = reader.read(UInt8.self) != 0
            let covers = (0..<reader.readCount()).map { _ in
                ImageItem(url: PathKey.url(reader.readString()), size: Int(reader.read(Int64.self)),
                          modified: Date(timeIntervalSince1970: reader.readDouble()))
            }
            guard reader.isValid else { return nil }
            entries[key] = (modified, Info(imageCount: imageCount, folderCount: folderCount, covers: covers,
                                           containsImages: containsImages))
        }
        return entries
    }

    private static func compute(_ url: URL) -> Info {
        let listing = FolderScanner.list(url)
        let covers = collectCovers(listing, limit: 4)
        let containsImages = !covers.isEmpty || listing.folders.contains { containsImage(in: $0.url) }
        return Info(imageCount: listing.images.count, folderCount: listing.folders.count, covers: covers,
                    containsImages: containsImages)
    }

    /// Walks the tree lazily and stops at the first image, so only truly empty trees are walked in full.
    static func containsImage(in url: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return false }
        for case let entry as URL in enumerator where ImageTypes.isImage(entry) {
            return true
        }
        return false
    }

    private static func byName(_ a: ImageItem, _ b: ImageItem) -> Bool {
        a.name.localizedStandardCompare(b.name) == .orderedAscending
    }

    /// Spreads the mosaic across the folder: its own images first, then the first image of each
    /// sub-album, so a folder of albums shows a bit of each. Bounded to keep it cheap.
    private static func collectCovers(_ listing: FolderScanner.Listing, limit: Int, depth: Int = 3) -> [ImageItem] {
        var covers: [ImageItem] = []
        let own = listing.images.sorted(by: byName)
        if own.count >= limit {
            // Evenly spaced samples rather than four near-identical neighbours.
            let step = Double(own.count) / Double(limit)
            return (0..<limit).map { own[Int(Double($0) * step)] }
        }
        covers.append(contentsOf: own)
        guard depth > 0 else { return covers }
        for folder in listing.folders.sorted(by: SortOrder(key: .name, ascending: true)).prefix(6) {
            guard covers.count < limit else { break }
            let inner = FolderScanner.list(folder.url)
            covers.append(contentsOf: collectCovers(inner, limit: 1, depth: depth - 1))
        }
        return covers
    }
}
