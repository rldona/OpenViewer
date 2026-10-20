import UIKit

/// Reads exact pixel colours from an image file. The file is decoded once (oriented, up to
/// 8192 px on its long side), off the main thread, the first time a colour is asked for.
final class PixelSampler {
    struct Sample: Equatable {
        let x: Int, y: Int
        let r: UInt8, g: UInt8, b: UInt8, a: UInt8

        var hex: String {
            a == 255 ? String(format: "#%02X%02X%02X", r, g, b) : String(format: "#%02X%02X%02X%02X", r, g, b, a)
        }
        var rgba: String { a == 255 ? "\(r), \(g), \(b)" : "\(r), \(g), \(b), \(Int((Double(a) / 255 * 100).rounded()))%" }
        var color: UIColor { UIColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: CGFloat(a) / 255) }
    }

    private let url: URL
    private var image: CGImage?
    private var loading = false
    private var waiting: [() -> Void] = []
    /// Size of the file's pixels (oriented); sampling coordinates refer to it.
    private(set) var pixelSize: CGSize = .zero

    init(url: URL) { self.url = url }

    /// Calls back on the main thread once the image is decoded (immediately if it already is).
    func prepare(_ done: @escaping () -> Void) {
        if image != nil { done(); return }
        waiting.append(done)
        guard !loading else { return }
        loading = true
        let url = self.url
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let size = ImagePipeline.pixelSize(of: url) ?? .zero
            let side = Int(min(max(size.width, size.height), 8192))
            let image = side > 0 ? ImagePipeline.downsample(url, maxPixel: side) : nil
            DispatchQueue.main.async {
                guard let self else { return }
                self.image = image
                self.pixelSize = size
                self.loading = false
                let callbacks = self.waiting
                self.waiting = []
                callbacks.forEach { $0() }
            }
        }
    }

    /// The pixel at a normalised position (0…1 on each axis), or nil outside the image.
    func sample(atUnit point: CGPoint) -> Sample? {
        guard let image, (0..<1).contains(point.x), (0..<1).contains(point.y) else { return nil }
        // Report coordinates in the file's own pixels even if the decode was capped at 8192.
        let fileX = Int(point.x * pixelSize.width), fileY = Int(point.y * pixelSize.height)
        let x = min(Int(point.x * CGFloat(image.width)), image.width - 1)
        let y = min(Int(point.y * CGFloat(image.height)), image.height - 1)
        guard let pixel = image.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { return nil }
        var data = [UInt8](repeating: 0, count: 4)
        // The file's own colour space, so the numbers match what an editor shows (no colour matching).
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                          space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.setBlendMode(.copy)
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard drawn else { return nil }
        // Un-premultiply so semi-transparent pixels report their real colour.
        let a = data[3]
        func straight(_ c: UInt8) -> UInt8 { a == 0 ? 0 : UInt8(min(255, (Int(c) * 255 + Int(a) / 2) / Int(a))) }
        return Sample(x: fileX, y: fileY, r: straight(data[0]), g: straight(data[1]), b: straight(data[2]), a: a)
    }
}

/// Thin lines on the boundaries between image pixels, drawn once each pixel is big enough on screen.
final class PixelGridView: UIView {
    /// The image's frame in this view's coordinates and its size in pixels.
    var imageFrame: CGRect = .zero { didSet { if imageFrame != oldValue { setNeedsDisplay() } } }
    var pixelSize: CGSize = .zero { didSet { if pixelSize != oldValue { setNeedsDisplay() } } }
    /// Minimum on-screen size of one image pixel, in points, for the grid to appear.
    static let threshold: CGFloat = 12

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError() }

    var pointsPerPixel: CGFloat {
        pixelSize.width > 0 ? imageFrame.width / pixelSize.width : 0
    }

    override func draw(_ rect: CGRect) {
        let step = pointsPerPixel
        guard step >= Self.threshold, let context = UIGraphicsGetCurrentContext() else { return }
        let visible = imageFrame.intersection(bounds)
        guard !visible.isNull else { return }
        let firstColumn = ((visible.minX - imageFrame.minX) / step).rounded(.down)
        let firstRow = ((visible.minY - imageFrame.minY) / step).rounded(.down)
        let path = CGMutablePath()
        var x = imageFrame.minX + firstColumn * step
        while x <= visible.maxX {
            if x >= visible.minX { path.move(to: CGPoint(x: x, y: visible.minY)); path.addLine(to: CGPoint(x: x, y: visible.maxY)) }
            x += step
        }
        var y = imageFrame.minY + firstRow * step
        while y <= visible.maxY {
            if y >= visible.minY { path.move(to: CGPoint(x: visible.minX, y: y)); path.addLine(to: CGPoint(x: visible.maxX, y: y)) }
            y += step
        }
        // Dark under light so the grid reads on any colour.
        let hairline = 1 / max(traitCollection.displayScale, 1)
        context.addPath(path)
        context.setStrokeColor(UIColor(white: 0, alpha: 0.35).cgColor)
        context.setLineWidth(hairline * 2)
        context.strokePath()
        context.addPath(path)
        context.setStrokeColor(UIColor(white: 1, alpha: 0.3).cgColor)
        context.setLineWidth(hairline)
        context.strokePath()
    }
}

/// Floating readout of the pixel under the finger: swatch, HEX, RGBA and coordinates.
final class PixelReadoutView: GlassView {
    private let swatch = UIView()
    private let hexLabel = UILabel()
    private let detailLabel = UILabel()
    private(set) var sample: PixelSampler.Sample?
    var onCopy: ((String) -> Void)?

    init() {
        super.init(cornerRadius: 18)
        swatch.layer.cornerRadius = 8
        swatch.layer.cornerCurve = .continuous
        swatch.layer.borderWidth = 1
        swatch.layer.borderColor = UIColor(white: 1, alpha: 0.3).cgColor
        swatch.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([swatch.widthAnchor.constraint(equalToConstant: 36), swatch.heightAnchor.constraint(equalToConstant: 36)])
        hexLabel.font = .monospacedSystemFont(ofSize: 17, weight: .semibold)
        hexLabel.textColor = .white
        detailLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        detailLabel.textColor = UIColor(white: 1, alpha: 0.75)
        let labels = UIStackView(arrangedSubviews: [hexLabel, detailLabel])
        labels.axis = .vertical
        labels.spacing = 1
        let copy = UIButton(type: .system, primaryAction: UIAction { [weak self] _ in
            guard let hex = self?.sample?.hex else { return }
            UIPasteboard.general.string = hex
            self?.onCopy?(hex)
        })
        copy.setImage(UIImage(systemName: "doc.on.doc"), for: .normal)
        copy.tintColor = .white
        copy.accessibilityLabel = "Copy Color"
        let row = UIStackView(arrangedSubviews: [swatch, labels, copy])
        row.spacing = 12
        row.alignment = .center
        embed(row, insets: NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 12))
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ sample: PixelSampler.Sample) {
        self.sample = sample
        swatch.backgroundColor = sample.color
        hexLabel.text = sample.hex
        detailLabel.text = "RGB \(sample.rgba) · x \(sample.x) y \(sample.y)"
        accessibilityLabel = "\(sample.hex), x \(sample.x), y \(sample.y)"
    }
}
