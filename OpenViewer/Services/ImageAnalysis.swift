import Foundation
import ImageIO
import os
import UIKit
import Vision

/// What OpenViewer learns about an image by looking at its pixels: main colours, a visual
/// fingerprint for finding duplicates, and any text in it. Computed in the background on demand,
/// and remembered per file (re-done only if the file changes).
struct ImageAnalysisRecord: Codable, Equatable {
    var modified: Date
    var size: Int
    /// Dominant colours, most common first, as 0xRRGGBB.
    var palette: [UInt32]?
    /// Share of the image (0…1) each palette colour covers.
    var weights: [Float]?
    /// 64-bit difference hash: near-identical images differ in only a few bits.
    var hash: UInt64?
    /// The same comparing vertical neighbours; both must agree for a duplicate.
    var vhash: UInt64?
    /// Bit per `ColorFamily` that makes up a meaningful part of the image.
    var families: UInt16?
    /// Text recognised in the image, lowercased; "" when it has none.
    var text: String?
}

enum AnalysisKind: CaseIterable {
    /// Palette and fingerprint (one small decode).
    case visual
    /// Text recognition (a large decode plus Vision; much slower).
    case text
}

// MARK: - Palette

enum ColorPalette {
    /// Dominant colours of `image`, merging near-identical shades. Fully transparent pixels are ignored.
    static func extract(from image: CGImage, maxColors: Int = 6) -> [(rgb: UInt32, weight: Float)] {
        let side = 48
        // Nearest-neighbour sampling: blended edges between two colours would show up as a third.
        guard let pixels = rgbaPixels(image, width: side, height: side, quality: .none) else { return [] }
        // 4 bits per channel: 4096 buckets, each remembering the average of its pixels.
        var counts = [Int](repeating: 0, count: 4096)
        var sums = [SIMD3<Int>](repeating: .zero, count: 4096)
        var total = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let a = Int(pixels[i + 3])
            guard a > 32 else { continue }
            let r = Int(pixels[i]) * 255 / a, g = Int(pixels[i + 1]) * 255 / a, b = Int(pixels[i + 2]) * 255 / a
            let bucket = (min(r, 255) >> 4) << 8 | (min(g, 255) >> 4) << 4 | (min(b, 255) >> 4)
            counts[bucket] += 1
            sums[bucket] &+= SIMD3(min(r, 255), min(g, 255), min(b, 255))
            total += 1
        }
        guard total > 0 else { return [] }
        let ranked = counts.indices.filter { counts[$0] > 0 }.sorted { counts[$0] > counts[$1] }
        var chosen: [(color: SIMD3<Int>, count: Int)] = []
        for bucket in ranked {
            let color = sums[bucket] / counts[bucket]
            if let index = chosen.firstIndex(where: { distance($0.color, color) < 48 }) {
                chosen[index].count += counts[bucket]
            } else if chosen.count < maxColors * 2 {
                chosen.append((color, counts[bucket]))
            }
        }
        return chosen.sorted { $0.count > $1.count }.prefix(maxColors)
            .filter { Float($0.count) / Float(total) >= 0.02 }
            .map { (UInt32($0.color.x) << 16 | UInt32($0.color.y) << 8 | UInt32($0.color.z), Float($0.count) / Float(total)) }
    }

    private static func distance(_ a: SIMD3<Int>, _ b: SIMD3<Int>) -> Int {
        let d = a &- b
        return Int(Double(d.x * d.x * 2 + d.y * d.y * 4 + d.z * d.z * 3).squareRoot() / 3)
    }

    /// Premultiplied RGBA bytes of `image` drawn at the given size.
    static func rgbaPixels(_ image: CGImage, width: Int, height: Int, quality: CGInterpolationQuality = .high) -> [UInt8]? {
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let ok = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = quality
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return ok ? data : nil
    }

    static func color(_ rgb: UInt32) -> UIColor {
        UIColor(red: CGFloat(rgb >> 16 & 0xFF) / 255, green: CGFloat(rgb >> 8 & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }

    static func hex(_ rgb: UInt32) -> String { String(format: "#%06X", rgb) }
}

/// Broad colour families used to filter the library ("everything mossy green").
enum ColorFamily: String, CaseIterable {
    case red, orange, yellow, green, teal, blue, purple, pink, brown, white, gray, black

    var title: String { rawValue.capitalized }

    var swatch: UIColor {
        switch self {
        case .red: return .systemRed
        case .orange: return .systemOrange
        case .yellow: return .systemYellow
        case .green: return .systemGreen
        case .teal: return .systemTeal
        case .blue: return .systemBlue
        case .purple: return .systemPurple
        case .pink: return .systemPink
        case .brown: return .systemBrown
        case .white: return .white
        case .gray: return .systemGray
        case .black: return .black
        }
    }

    static func of(_ rgb: UInt32) -> ColorFamily {
        let color = ColorPalette.color(rgb)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0
        color.getHue(&h, saturation: &s, brightness: &b, alpha: nil)
        if b < 0.18 { return .black }
        if s < 0.15 { return b > 0.85 ? .white : .gray }
        let degrees = h * 360
        if s < 0.6 && b < 0.6 && (degrees < 50 || degrees >= 345) { return .brown }
        switch degrees {
        case ..<15, 345...: return .red
        case ..<40: return b < 0.65 ? .brown : .orange
        case ..<68: return .yellow
        case ..<165: return .green
        case ..<195: return .teal
        case ..<255: return .blue
        case ..<290: return .purple
        default: return .pink
        }
    }

    var bit: UInt16 { 1 << UInt16(Self.allCases.firstIndex(of: self)!) }

    /// Families that make up at least 12 % of the image, as a bitmask.
    static func mask(palette: [UInt32], weights: [Float]) -> UInt16 {
        var shares: [ColorFamily: Float] = [:]
        for (index, rgb) in palette.enumerated() {
            shares[of(rgb), default: 0] += index < weights.count ? weights[index] : 0
        }
        return shares.filter { $0.value >= 0.12 }.keys.reduce(0) { $0 | $1.bit }
    }
}

// MARK: - Fingerprint

enum ImageHash {
    /// Difference hash: 9×8 grey thumbnail, one bit per horizontal neighbour comparison.
    /// Each cell is the average of an 8×8 block, so fine detail and resizing don't flip bits.
    static func dHash(_ image: CGImage) -> UInt64? { hashes(image)?.horizontal }

    /// Horizontal and vertical difference hashes from one 9×9 grid of block averages.
    static func hashes(_ image: CGImage) -> (horizontal: UInt64, vertical: UInt64)? {
        let block = 8, cellsPerSide = 9
        let side = cellsPerSide * block
        guard let pixels = ColorPalette.rgbaPixels(image, width: side, height: side) else { return nil }
        var cells = [Int](repeating: 0, count: cellsPerSide * cellsPerSide)
        for y in 0..<side {
            for x in 0..<side {
                let i = (y * side + x) * 4
                // Transparent areas count as mid-grey so sprites on any background compare alike.
                let a = Int(pixels[i + 3])
                let lum = (Int(pixels[i]) * 299 + Int(pixels[i + 1]) * 587 + Int(pixels[i + 2]) * 114) / 1000
                cells[(y / block) * cellsPerSide + x / block] += lum + (255 - a) / 2
            }
        }
        func grey(_ x: Int, _ y: Int) -> Int { cells[y * cellsPerSide + x] }
        var horizontal: UInt64 = 0, vertical: UInt64 = 0
        for y in 0..<8 {
            for x in 0..<8 {
                horizontal <<= 1
                vertical <<= 1
                // A small margin so flat areas (equal neighbours) don't flip on rounding noise.
                if grey(x, y) > grey(x + 1, y) + 64 { horizontal |= 1 }
                if grey(x, y) > grey(x, y + 1) + 64 { vertical |= 1 }
            }
        }
        return (horizontal, vertical)
    }

    static func distance(_ a: UInt64, _ b: UInt64) -> Int { (a ^ b).nonzeroBitCount }
}

// MARK: - Store

/// Remembered analysis per file (keyed like favourites). Main-thread API.
final class ImageAnalysisStore {
    static let shared = ImageAnalysisStore(fileURL: FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("OpenViewer/analysis.plist"))

    static let didChange = Notification.Name("OpenViewer.analysisDidChange")

    private var records: [String: ImageAnalysisRecord] = [:]
    private let fileURL: URL?
    private var saveScheduled = false

    init(fileURL: URL?) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let stored = try? PropertyListDecoder().decode([String: ImageAnalysisRecord].self, from: data) {
            records = stored
        }
    }

    /// The record for `item`, only if it still describes the file as it is now.
    func record(for item: ImageItem) -> ImageAnalysisRecord? {
        guard let record = records[FavoritesStore.key(item.url)],
              record.size == item.size, abs(record.modified.timeIntervalSince(item.modified)) < 1 else { return nil }
        return record
    }

    func has(_ kind: AnalysisKind, for item: ImageItem) -> Bool {
        guard let record = record(for: item) else { return false }
        switch kind {
        case .visual: return record.hash != nil && record.vhash != nil && record.families != nil
        case .text: return record.text != nil
        }
    }

    /// Keys of analysed files that contain the colour family.
    func keys(matching family: ColorFamily) -> Set<String> {
        let bit = family.bit
        return Set(records.lazy.filter { ($0.value.families ?? 0) & bit != 0 }.map(\.key))
    }

    /// Keys of files whose recognised text contains `query` (case-insensitive).
    func keys(containingText query: String) -> Set<String> {
        let needle = query.lowercased()
        return Set(records.lazy.filter { $0.value.text?.contains(needle) ?? false }.map(\.key))
    }

    func update(_ item: ImageItem, _ change: (inout ImageAnalysisRecord) -> Void) {
        var record = record(for: item) ?? ImageAnalysisRecord(modified: item.modified, size: item.size)
        change(&record)
        records[FavoritesStore.key(item.url)] = record
        scheduleSave()
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.saveScheduled = false
            self.save()
        }
    }

    func save() {
        guard let fileURL else { return }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let snapshot = records
        DispatchQueue.global(qos: .utility).async {
            guard let data = try? encoder.encode(snapshot) else { return }
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

// MARK: - Analysis

struct VisualAnalysis {
    let palette: [UInt32]
    let weights: [Float]
    let hash: UInt64
    let vhash: UInt64
    let families: UInt16
}

extension ImageAnalysisRecord {
    mutating func apply(_ visual: VisualAnalysis?) {
        palette = visual?.palette ?? []
        weights = visual?.weights ?? []
        hash = visual?.hash ?? 0
        vhash = visual?.vhash ?? 0
        families = visual?.families ?? 0
    }
}

enum ImageAnalyzer {
    /// Palette and fingerprint from one small decode.
    static func visual(_ url: URL) -> VisualAnalysis? {
        guard let image = ImagePipeline.downsample(url, maxPixel: 160) else { return nil }
        return visual(image)
    }

    static func visual(_ image: CGImage) -> VisualAnalysis? {
        guard let hashes = ImageHash.hashes(image) else { return nil }
        let palette = ColorPalette.extract(from: image)
        let rgb = palette.map(\.rgb), weights = palette.map(\.weight)
        return VisualAnalysis(palette: rgb, weights: weights, hash: hashes.horizontal, vhash: hashes.vertical,
                              families: ColorFamily.mask(palette: rgb, weights: weights))
    }

    /// Recognised text, lowercased ("" when there is none).
    static func text(_ url: URL) -> String? {
        guard let image = ImagePipeline.downsample(url, maxPixel: 2400) else { return nil }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["es-ES", "en-US"]
        request.minimumTextHeight = 0.008
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil else { return "" }
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n").lowercased()
    }
}

/// Works through a list of images in the background, skipping ones already analysed, and reports
/// progress on the main thread. Results are saved as they come, so a cancelled run resumes later.
final class AnalysisJob {
    let kind: AnalysisKind
    private(set) var done = 0
    private(set) var total = 0
    private let cancelled = OSAllocatedUnfairLock(initialState: false)
    private let queue = OperationQueue()
    var onProgress: ((Int, Int) -> Void)?
    var onFinish: (() -> Void)?

    init(kind: AnalysisKind) { self.kind = kind }

    var isCancelled: Bool { cancelled.withLock { $0 } }
    func cancel() {
        cancelled.withLock { $0 = true }
        queue.cancelAllOperations()
    }

    func start(_ items: [ImageItem]) {
        let store = ImageAnalysisStore.shared
        let pending = items.filter { !store.has(kind, for: $0) }
        total = pending.count
        done = 0
        guard !pending.isEmpty else {
            onProgress?(0, 0)
            onFinish?()
            return
        }
        onProgress?(0, total)
        let kind = self.kind
        queue.qualityOfService = .utility
        // Text recognition is heavy on memory: fewer at a time.
        queue.maxConcurrentOperationCount = kind == .text ? 2 : max(2, ProcessInfo.processInfo.activeProcessorCount - 2)
        for item in pending {
            queue.addOperation { [weak self] in
                guard let self, !self.isCancelled else { return }
                autoreleasepool {
                    switch kind {
                    case .visual:
                        let result = ImageAnalyzer.visual(item.url)
                        DispatchQueue.main.async {
                            store.update(item) { $0.apply(result) }
                            self.advance()
                        }
                    case .text:
                        let text = ImageAnalyzer.text(item.url) ?? ""
                        DispatchQueue.main.async {
                            store.update(item) { $0.text = text }
                            self.advance()
                        }
                    }
                }
            }
        }
    }

    private func advance() {
        guard !isCancelled else { return }
        done += 1
        // Throttle UI updates on huge runs.
        if done == total || done % 25 == 0 { onProgress?(done, total) }
        if done == total {
            ImageAnalysisStore.shared.save()
            NotificationCenter.default.post(name: ImageAnalysisStore.didChange, object: nil)
            onFinish?()
        }
    }
}
