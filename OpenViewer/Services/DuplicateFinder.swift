import Foundation

/// Groups visually identical or near-identical images and ranks similar ones, from the
/// fingerprints and palettes in `ImageAnalysisStore`.
enum DuplicateFinder {
    /// Groups of indices that look identical or nearly so (largest groups first). Each group is built
    /// around its first image and only takes images close to *that* image, so a long chain of
    /// slightly different pictures never collapses into one giant group.
    /// Fingerprints are split into `maxDistance + 1` chunks: two hashes that close must share one
    /// chunk exactly, so only those candidates are compared — fast even for 100k images.
    static func groups(_ prints: [Signature?], maxDistance: Int = 3, maxPaletteDistance: Double = 0.08) -> [[Int]] {
        let chunkCount = maxDistance + 1
        let chunkBits = 64 / chunkCount
        func chunk(_ hash: UInt64, _ index: Int) -> UInt64 {
            let bits = index == chunkCount - 1 ? 64 - index * chunkBits : chunkBits
            return (hash >> UInt64(index * chunkBits)) & ((1 << UInt64(bits)) - 1)
        }
        var buckets = [[UInt64: [Int]]](repeating: [:], count: chunkCount)
        for (index, print) in prints.enumerated() {
            guard let print, print.isDistinctive else { continue }
            for c in 0..<chunkCount { buckets[c][chunk(print.hash, c), default: []].append(index) }
        }
        var assigned = [Bool](repeating: false, count: prints.count)
        var result: [[Int]] = []
        for (anchor, print) in prints.enumerated() {
            guard let print, print.isDistinctive, !assigned[anchor] else { continue }
            var members = [anchor]
            var seen: Set<Int> = [anchor]
            for c in 0..<chunkCount {
                for other in buckets[c][chunk(print.hash, c)] ?? [] where !assigned[other] && seen.insert(other).inserted {
                    guard let candidate = prints[other] else { continue }
                    if ImageHash.distance(print.hash, candidate.hash) <= maxDistance,
                       ImageHash.distance(print.vhash, candidate.vhash) <= maxDistance,
                       paletteDistance(print, candidate) <= maxPaletteDistance {
                        members.append(other)
                    }
                }
            }
            guard members.count > 1 else { continue }
            members.sort()
            members.forEach { assigned[$0] = true }
            result.append(members)
        }
        return result.sorted { $0.count != $1.count ? $0.count > $1.count : $0[0] < $1[0] }
    }

    struct Signature {
        let hash: UInt64
        var vhash: UInt64 = 0
        let palette: [UInt32]
        let weights: [Float]

        /// Flat or nearly flat images have (almost) empty fingerprints that would match each other.
        var isDistinctive: Bool { hash.nonzeroBitCount + vhash.nonzeroBitCount >= 4 }
    }

    /// How different two images look (0 = identical): shape from the fingerprints plus colour.
    static func score(_ a: Signature, _ b: Signature) -> Double {
        Double(ImageHash.distance(a.hash, b.hash) + ImageHash.distance(a.vhash, b.vhash)) / 2 + 24 * paletteDistance(a, b)
    }

    /// 0…1: for each main colour of A (by weight), how far the closest colour of B is.
    static func paletteDistance(_ a: Signature, _ b: Signature) -> Double {
        guard !a.palette.isEmpty, !b.palette.isEmpty else { return 0.5 }
        var total = 0.0, weightSum = 0.0
        for (index, rgb) in a.palette.enumerated() {
            let weight = Double(index < a.weights.count ? a.weights[index] : 0.1)
            let nearest = b.palette.map { rgbDistance(rgb, $0) }.min() ?? 1
            total += weight * nearest
            weightSum += weight
        }
        return weightSum > 0 ? total / weightSum : 0.5
    }

    private static func rgbDistance(_ a: UInt32, _ b: UInt32) -> Double {
        let dr = Double(Int(a >> 16 & 0xFF) - Int(b >> 16 & 0xFF))
        let dg = Double(Int(a >> 8 & 0xFF) - Int(b >> 8 & 0xFF))
        let db = Double(Int(a & 0xFF) - Int(b & 0xFF))
        return min((dr * dr + dg * dg + db * db).squareRoot() / 441.7, 1)
    }

    /// Indices of the most similar candidates, best first.
    static func similar(to target: Signature, among candidates: [Signature?], limit: Int = 60, maxScore: Double = 22) -> [Int] {
        candidates.enumerated()
            .compactMap { index, signature in signature.map { (index, score(target, $0)) } }
            .filter { $0.1 <= maxScore }
            .sorted { $0.1 < $1.1 }
            .prefix(limit)
            .map(\.0)
    }
}
