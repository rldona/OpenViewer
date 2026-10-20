import LinkPresentation
import UIKit
import UniformTypeIdentifiers

/// The system share sheet, shown as a centred card (like Photos) instead of a popover hanging off
/// a button. It shares the original files with their real type, so every image action the system
/// and installed apps offer appears (Save Image, Copy, Print, Assign to Contact, AirDrop, Files…),
/// and its header previews what is being shared with a thumbnail from the cache.
enum ShareSheet {
    static func present(_ urls: [URL], preview: ImageItem? = nil, from presenter: UIViewController) {
        guard !urls.isEmpty else { return }
        let header = ShareHeader(urls: urls, preview: preview)
        let sources = urls.map { ShareItem(url: $0, header: header) }
        let activity = UIActivityViewController(activityItems: sources, applicationActivities: nil)
        if let popover = activity.popoverPresentationController, let view = presenter.view {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        presenter.present(activity, animated: true)
    }
}

/// Title and thumbnail for the sheet's header, built once for the whole share.
private final class ShareHeader {
    let metadata = LPLinkMetadata()

    init(urls: [URL], preview: ImageItem?) {
        let imageCount = urls.filter { ImageTypes.isImage($0) }.count
        if urls.count == 1 {
            metadata.title = urls[0].lastPathComponent
        } else if imageCount == urls.count {
            metadata.title = "\(urls.count.formatted()) Images"
        } else {
            metadata.title = "\(urls.count.formatted()) Items"
        }
        metadata.originalURL = urls.count == 1 ? urls[0] : nil
        if let preview, let thumbnail = Self.cachedThumbnail(for: preview) {
            metadata.imageProvider = NSItemProvider(object: thumbnail)
        } else if urls.count == 1, !ImageTypes.isImage(urls[0]), let folder = UIImage(systemName: "folder.fill") {
            metadata.iconProvider = NSItemProvider(object: folder)
        }
    }

    private static func cachedThumbnail(for item: ImageItem) -> UIImage? {
        for bucket in ImagePipeline.thumbnailBuckets.reversed() {
            if let image = ImagePipeline.thumbnails.cachedImage(for: .init(item, maxPixel: bucket)) { return image }
        }
        return nil
    }
}

private final class ShareItem: NSObject, UIActivityItemSource {
    private let url: URL
    private let header: ShareHeader

    init(url: URL, header: ShareHeader) {
        self.url = url
        self.header = header
    }

    func activityViewControllerPlaceholderItem(_ activityViewController: UIActivityViewController) -> Any { url }

    func activityViewController(_ activityViewController: UIActivityViewController,
                                itemForActivityType activityType: UIActivity.ActivityType?) -> Any? { url }

    func activityViewController(_ activityViewController: UIActivityViewController,
                                dataTypeIdentifierForActivityType activityType: UIActivity.ActivityType?) -> String {
        (url.hasDirectoryPath ? UTType.folder : UTType(filenameExtension: url.pathExtension) ?? .data).identifier
    }

    func activityViewController(_ activityViewController: UIActivityViewController,
                                subjectForActivityType activityType: UIActivity.ActivityType?) -> String {
        header.metadata.title ?? url.lastPathComponent
    }

    func activityViewControllerLinkMetadata(_ activityViewController: UIActivityViewController) -> LPLinkMetadata? {
        header.metadata
    }
}
