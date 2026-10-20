import Foundation

/// Lazily computed summary (counts + cover image) for folder cells. Main-thread API.
final class FolderInfoCache {
    struct Info {
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

    static let shared = FolderInfoCache()

    private var cache: [URL: Info] = [:]
    private var pending: [URL: [(Info) -> Void]] = [:]
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 3
        queue.qualityOfService = .utility
        return queue
    }()

    func cached(_ url: URL) -> Info? { cache[url] }

    func info(for url: URL, completion: @escaping (Info) -> Void) {
        if let info = cache[url] { completion(info); return }
        if pending[url] != nil { pending[url]?.append(completion); return }
        pending[url] = [completion]
        queue.addOperation { [weak self] in
            let info = Self.compute(url)
            DispatchQueue.main.async {
                guard let self else { return }
                self.cache[url] = info
                self.pending.removeValue(forKey: url)?.forEach { $0(info) }
            }
        }
    }

    func invalidate() { cache.removeAll() }

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
