import Foundation

/// Lazily computed summary (counts + cover image) for folder cells. Main-thread API.
final class FolderInfoCache {
    struct Info {
        let imageCount: Int
        let folderCount: Int
        let cover: ImageItem?

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
        let cover = firstImage(in: listing) ?? deepCover(in: listing.folders, depth: 3)
        return Info(imageCount: listing.images.count, folderCount: listing.folders.count, cover: cover)
    }

    private static func firstImage(in listing: FolderScanner.Listing) -> ImageItem? {
        listing.images.min { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Depth-first look into the first few subfolders so folders that only contain
    /// sub-albums still get a cover. Bounded to keep it cheap.
    private static func deepCover(in folders: [FolderItem], depth: Int) -> ImageItem? {
        guard depth > 0 else { return nil }
        for folder in folders.sorted(by: SortOrder(key: .name, ascending: true)).prefix(4) {
            let inner = FolderScanner.list(folder.url)
            if let image = firstImage(in: inner) ?? deepCover(in: inner.folders, depth: depth - 1) {
                return image
            }
        }
        return nil
    }
}
