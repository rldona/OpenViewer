import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Decides whether a file is an image by extension only — no file I/O, so it is cheap
/// enough to call for every entry of a 100k-file tree.
enum ImageTypes {
    static let extensions: Set<String> = {
        var set: Set<String> = [
            "jpg", "jpeg", "jpe", "jfif", "png", "gif", "heic", "heif", "webp", "tif", "tiff",
            "bmp", "avif", "jxl", "ico", "tga", "psd",
            // RAW formats ImageIO can read (it usually uses the embedded preview).
            "dng", "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf", "rw2",
            "pef", "srw", "3fr", "erf", "mrw", "x3f",
        ]
        // Add everything else this OS version's ImageIO can decode.
        if let identifiers = CGImageSourceCopyTypeIdentifiers() as? [String] {
            for identifier in identifiers {
                UTType(identifier)?.tags[.filenameExtension]?.forEach { set.insert($0.lowercased()) }
            }
        }
        set.subtract(["pdf", "ai", "eps"])
        return set
    }()

    static func isImage(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }
}
