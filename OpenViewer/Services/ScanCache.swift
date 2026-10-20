import CryptoKit
import Foundation

/// A persisted picture of a folder tree: every directory with its modification date, its
/// subfolders and its images, each list already in natural name order.
struct ScanSnapshot: Codable {
    static let currentVersion = 1

    struct File: Codable {
        var name: String
        var size: Int
        var modified: Double
    }

    struct Directory: Codable {
        /// Directory modification date; it changes when entries are added, removed or renamed.
        var modified: Double
        var subdirectories: [String]
        var files: [File]
    }

    var version = ScanSnapshot.currentVersion
    /// Keyed by path relative to the root ("" is the root itself).
    var directories: [String: Directory] = [:]

    /// Every image, depth first: a folder's own images, then each subfolder in name order.
    func images(root: URL) -> [ImageItem] {
        var images: [ImageItem] = []
        var stack: [(URL, String)] = [(root, "")]
        while let (url, relative) = stack.popLast() {
            guard let directory = directories[relative] else { continue }
            Self.append(directory, at: url, to: &images)
            for name in directory.subdirectories.reversed() {
                stack.append((url.appendingPathComponent(name, isDirectory: true), Self.join(relative, name)))
            }
        }
        return images
    }

    fileprivate static func append(_ directory: Directory, at url: URL, to images: inout [ImageItem]) {
        for file in directory.files {
            images.append(ImageItem(url: url.appendingPathComponent(file.name, isDirectory: false),
                                    size: file.size, modified: Date(timeIntervalSince1970: file.modified)))
        }
    }

    fileprivate static func join(_ relative: String, _ name: String) -> String {
        relative.isEmpty ? name : relative + "/" + name
    }
}

/// Stores one snapshot per root folder in Caches. All functions are synchronous; call them off the main thread.
enum ScanCache {
    private static let directory: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appendingPathComponent("OpenViewer/scans", isDirectory: true)

    private static func fileURL(for root: URL) -> URL? {
        let key = PathKey.make(root.standardizedFileURL.path)
        let name = SHA256.hash(data: Data(key.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return directory?.appendingPathComponent(name + ".plist")
    }

    static func load(root: URL) -> ScanSnapshot? {
        guard let url = fileURL(for: root), let data = try? Data(contentsOf: url),
              let snapshot = try? PropertyListDecoder().decode(ScanSnapshot.self, from: data),
              snapshot.version == ScanSnapshot.currentVersion else { return nil }
        return snapshot
    }

    static func save(_ snapshot: ScanSnapshot, root: URL) {
        guard let url = fileURL(for: root) else { return }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(snapshot) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    static func remove(root: URL) {
        guard let url = fileURL(for: root) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

/// Walks a folder tree reusing a previous snapshot: folders whose modification date is unchanged
/// are not listed again, so revisiting a huge tree only costs one metadata read per folder.
enum IncrementalScanner {
    struct Result {
        var images: [ImageItem]
        var snapshot: ScanSnapshot
        /// Folders that had to be listed again (all of them on a first scan).
        var changedDirectories: Int
    }

    private static let listKeys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey]

    /// Returns `nil` if cancelled. `onProgress` receives the images found so far, at most every
    /// `progressInterval` seconds, in final order.
    static func scan(root: URL,
                     previous: ScanSnapshot?,
                     progressInterval: CFTimeInterval = 0.25,
                     isCancelled: () -> Bool,
                     onProgress: ([ImageItem]) -> Void = { _ in }) -> Result? {
        var snapshot = ScanSnapshot()
        var images: [ImageItem] = []
        var changed = 0
        var lastProgress = CFAbsoluteTimeGetCurrent()
        var stack: [(URL, String)] = [(root, "")]

        while let (url, relative) = stack.popLast() {
            if isCancelled() { return nil }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate?.timeIntervalSince1970 ?? 0

            let directory: ScanSnapshot.Directory
            if let cached = previous?.directories[relative], modified != 0, cached.modified == modified {
                directory = cached
            } else {
                changed += 1
                directory = list(url, modified: modified)
            }
            snapshot.directories[relative] = directory
            ScanSnapshot.append(directory, at: url, to: &images)
            for name in directory.subdirectories.reversed() {
                stack.append((url.appendingPathComponent(name, isDirectory: true), ScanSnapshot.join(relative, name)))
            }

            let now = CFAbsoluteTimeGetCurrent()
            if now - lastProgress >= progressInterval {
                onProgress(images)
                lastProgress = now
            }
        }
        return Result(images: images, snapshot: snapshot, changedDirectories: changed)
    }

    private static func list(_ url: URL, modified: Double) -> ScanSnapshot.Directory {
        var subdirectories: [String] = []
        var files: [ScanSnapshot.File] = []
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: listKeys, options: [.skipsHiddenFiles])) ?? []
        for entry in entries {
            let values = try? entry.resourceValues(forKeys: Set(listKeys))
            if values?.isDirectory == true {
                if values?.isPackage != true { subdirectories.append(entry.lastPathComponent) }
            } else if ImageTypes.isImage(entry) {
                files.append(ScanSnapshot.File(name: entry.lastPathComponent, size: values?.fileSize ?? 0,
                                               modified: values?.contentModificationDate?.timeIntervalSince1970 ?? 0))
            }
        }
        subdirectories.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        files.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return ScanSnapshot.Directory(modified: modified, subdirectories: subdirectories, files: files)
    }
}
