import ImageIO
import UIKit

/// Lightweight file + EXIF details, read from the image header only.
final class InfoViewController: UITableViewController {
    private let item: ImageItem
    private var sections: [(title: String, rows: [(String, String)])] = []

    init(item: ImageItem) {
        self.item = item
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Info"
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        tableView.allowsSelection = false
        let url = item.url
        let item = self.item
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let sections = Self.buildSections(item: item, url: url)
            DispatchQueue.main.async {
                self?.sections = sections
                self?.tableView.reloadData()
            }
        }
    }

    private static func buildSections(item: ImageItem, url: URL) -> [(title: String, rows: [(String, String)])] {
        var file: [(String, String)] = [
            ("Name", item.name),
            ("Folder", url.deletingLastPathComponent().lastPathComponent),
            ("Size", ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file)),
            ("Modified", item.modified.formatted(date: .abbreviated, time: .shortened)),
        ]
        var camera: [(String, String)] = []

        if let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            if let type = CGImageSourceGetType(source) as String? {
                file.insert(("Format", type.components(separatedBy: ".").last?.uppercased() ?? type), at: 2)
            }
            if let size = ImagePipeline.pixelSize(of: url) {
                let mp = size.width * size.height / 1_000_000
                file.insert(("Dimensions", "\(Int(size.width)) × \(Int(size.height)) (\(String(format: "%.1f", mp)) MP)"), at: 2)
            }
            let frames = CGImageSourceGetCount(source)
            if frames > 1 { file.append(("Frames", "\(frames)")) }

            let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
            let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
            if let make = tiff[kCGImagePropertyTIFFMake] as? String, let model = tiff[kCGImagePropertyTIFFModel] as? String {
                camera.append(("Camera", model.hasPrefix(make) ? model : "\(make) \(model)"))
            }
            if let lens = exif[kCGImagePropertyExifLensModel] as? String { camera.append(("Lens", lens)) }
            if let date = exif[kCGImagePropertyExifDateTimeOriginal] as? String { camera.append(("Taken", date)) }
            if let focal = exif[kCGImagePropertyExifFocalLength] as? Double { camera.append(("Focal Length", "\(Int(focal.rounded())) mm")) }
            if let f = exif[kCGImagePropertyExifFNumber] as? Double { camera.append(("Aperture", "ƒ/\(String(format: "%.1f", f))")) }
            if let t = exif[kCGImagePropertyExifExposureTime] as? Double {
                camera.append(("Shutter", t >= 1 ? "\(t) s" : "1/\(Int((1 / t).rounded())) s"))
            }
            if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first { camera.append(("ISO", "\(iso)")) }
        }

        var result: [(title: String, rows: [(String, String)])] = [("File", file)]
        if !camera.isEmpty { result.append(("Camera", camera)) }
        return result
    }

    override func numberOfSections(in tableView: UITableView) -> Int { sections.count }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { sections[section].title }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { sections[section].rows.count }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        var content = UIListContentConfiguration.valueCell()
        let row = sections[indexPath.section].rows[indexPath.row]
        content.text = row.0
        content.secondaryText = row.1
        content.prefersSideBySideTextAndSecondaryText = true
        cell.contentConfiguration = content
        return cell
    }
}
