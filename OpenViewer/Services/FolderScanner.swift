import Foundation

/// File-system listing. All functions are synchronous and meant to be called off the main thread.
enum FolderScanner {
    static let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey]

    struct Listing {
        var folders: [FolderItem] = []
        var images: [ImageItem] = []
    }

    /// Immediate children of `directory`.
    static func list(_ directory: URL) -> Listing {
        var listing = Listing()
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]
        ) else { return listing }

        for url in urls {
            guard let values = try? url.resourceValues(forKeys: keys) else { continue }
            let modified = values.contentModificationDate ?? .distantPast
            if values.isDirectory == true {
                if values.isPackage != true {
                    listing.folders.append(FolderItem(url: url, modified: modified))
                }
            } else if ImageTypes.isImage(url) {
                listing.images.append(ImageItem(url: url, size: values.fileSize ?? 0, modified: modified))
            }
        }
        return listing
    }

    /// Every image below `root`, streamed in batches roughly every `flushInterval` seconds so the UI
    /// can show results while a huge tree is still being walked.
    static func scanRecursively(
        _ root: URL,
        flushInterval: CFTimeInterval = 0.25,
        isCancelled: () -> Bool,
        onBatch: ([ImageItem]) -> Void
    ) {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return }

        var batch: [ImageItem] = []
        batch.reserveCapacity(1024)
        var lastFlush = CFAbsoluteTimeGetCurrent()

        for case let url as URL in enumerator {
            if isCancelled() { return }
            // Extension check first: it avoids touching metadata for non-image files.
            guard ImageTypes.isImage(url),
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isDirectory != true
            else { continue }
            batch.append(ImageItem(url: url, size: values.fileSize ?? 0,
                                   modified: values.contentModificationDate ?? .distantPast))

            let now = CFAbsoluteTimeGetCurrent()
            if now - lastFlush >= flushInterval {
                onBatch(batch)
                batch.removeAll(keepingCapacity: true)
                lastFlush = now
            }
        }
        if !isCancelled() { onBatch(batch) }
    }
}
