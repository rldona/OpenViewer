import UIKit

extension UIViewController {
    /// Runs an analysis over `items` with a cancellable progress dialog, then calls `completion`
    /// (not called if cancelled). Already analysed images are skipped, so repeat runs are instant.
    func runAnalysis(_ kind: AnalysisKind, on items: [ImageItem], title: String, completion: @escaping () -> Void) {
        let job = AnalysisJob(kind: kind)
        var alert: UIAlertController?
        var finished = false
        job.onProgress = { done, total in
            guard total > 0 else { return }
            alert?.message = "Looking at \(done.formatted()) of \(total.formatted()) images…\nResults are remembered for next time."
        }
        job.onFinish = { [weak self] in
            finished = true
            if let alert, alert.presentingViewController != nil {
                alert.dismiss(animated: true) { completion() }
            } else {
                completion()
            }
            _ = self
        }
        job.start(items)
        guard !finished else { return }
        let dialog = UIAlertController(title: title, message: "Getting ready…", preferredStyle: .alert)
        dialog.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in job.cancel() })
        alert = dialog
        // Keep the job alive while the dialog is up.
        objc_setAssociatedObject(dialog, &analysisJobKey, job, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        present(dialog, animated: true)
    }

    /// Shows a collection in its own full-screen browser.
    func presentCollection(_ collection: ImageCollection) {
        let browser = BrowserViewController(collection: collection)
        let navigation = RootNavigationController(rootViewController: browser)
        navigation.modalPresentationStyle = .fullScreen
        var presenter: UIViewController = self
        while let presented = presenter.presentedViewController { presenter = presented }
        presenter.present(navigation, animated: true)
    }

    func showMessage(_ title: String, _ message: String? = nil) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

private var analysisJobKey: UInt8 = 0

enum AnalysisFlows {
    /// Fingerprints of `items` from the store (main thread).
    static func signatures(of items: [ImageItem]) -> [DuplicateFinder.Signature?] {
        let store = ImageAnalysisStore.shared
        return items.map { item in
            guard let record = store.record(for: item), let hash = record.hash else { return nil }
            return .init(hash: hash, vhash: record.vhash ?? 0, palette: record.palette ?? [], weights: record.weights ?? [])
        }
    }

    /// Groups of identical or near-identical images among `items`, as a collection (nil if none).
    /// Safe off the main thread.
    static func duplicates(in items: [ImageItem], signatures: [DuplicateFinder.Signature?]) -> ImageCollection? {
        let groups = DuplicateFinder.groups(signatures)
        guard !groups.isEmpty else { return nil }
        var images: [ImageItem] = []
        var groupOf: [URL: Int] = [:]
        var titles: [Int: String] = [:]
        for (id, group) in groups.enumerated() {
            // The one worth keeping first: most pixels, then biggest file, then the oldest.
            let members = group.map { items[$0] }.map { item -> (ImageItem, CGFloat) in
                let size = ImagePipeline.pixelSize(of: item.url) ?? .zero
                return (item, size.width * size.height)
            }.sorted { a, b in
                if a.1 != b.1 { return a.1 > b.1 }
                if a.0.size != b.0.size { return a.0.size > b.0.size }
                return a.0.modified < b.0.modified
            }.map(\.0)
            for item in members { groupOf[item.url] = id }
            images += members
            titles[id] = "Keep “\(members[0].name)”"
        }
        let wasted = groups.reduce(0) { total, group in
            total + group.map { items[$0].size }.sorted(by: >).dropFirst().reduce(0, +)
        }
        let title = "Duplicates · \(ByteCountFormatter.string(fromByteCount: Int64(wasted), countStyle: .file)) in copies"
        return ImageCollection(title: title, images: images, groupOf: groupOf, groupTitles: titles, isDuplicates: true)
    }

    /// `item` followed by the images that look most like it.
    static func similar(to item: ImageItem, in items: [ImageItem]) -> ImageCollection? {
        let signatures = signatures(of: items)
        guard let index = items.firstIndex(of: item), let target = signatures[index], target.isDistinctive else { return nil }
        var candidates = signatures
        candidates[index] = nil
        let ranked = DuplicateFinder.similar(to: target, among: candidates)
        guard !ranked.isEmpty else { return nil }
        let matches = ranked.map { items[$0] }
        var groupOf: [URL: Int] = [item.url: 0]
        for match in matches { groupOf[match.url] = 1 }
        return ImageCollection(title: "Similar to \(item.name)", images: [item] + matches, groupOf: groupOf,
                               groupTitles: [0: "This Image", 1: "Most Similar First"])
    }
}
