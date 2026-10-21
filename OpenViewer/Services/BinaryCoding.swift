import Foundation

/// Minimal little-endian binary format for the app's large persisted tables (scan snapshots,
/// image analysis, image metrics). Codable property lists took ~0.5 s to read 100k entries on an
/// A12X; this reads the same in a few tens of milliseconds.
struct BinaryWriter {
    private(set) var data = Data()

    init(magic: String, version: UInt32) {
        data.reserveCapacity(1 << 16)
        data.append(contentsOf: Array(magic.utf8.prefix(4)))
        write(version)
    }

    mutating func write<T: FixedWidthInteger>(_ value: T) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    mutating func write(_ value: Double) { write(value.bitPattern) }
    mutating func write(_ value: Float) { write(value.bitPattern) }

    /// Variable-length unsigned integer (1 byte below 128).
    mutating func writeCount(_ value: Int) {
        var v = UInt64(max(value, 0))
        while v >= 0x80 {
            data.append(UInt8(v & 0x7F) | 0x80)
            v >>= 7
        }
        data.append(UInt8(v))
    }

    mutating func write(_ string: String) {
        var string = string
        string.withUTF8 { bytes in
            writeCount(bytes.count)
            data.append(bytes.baseAddress!, count: bytes.count)
        }
    }
}

/// Reads what `BinaryWriter` wrote. Every read is bounds-checked: a truncated or foreign file
/// makes `isValid` false instead of crashing.
struct BinaryReader {
    private let bytes: [UInt8]
    private var offset = 0
    private(set) var isValid = true

    init?(data: Data, magic: String, version: UInt32) {
        bytes = [UInt8](data)
        let tag = Array(magic.utf8.prefix(4))
        guard bytes.count >= tag.count + 4, Array(bytes[0..<tag.count]) == tag else { return nil }
        offset = tag.count
        guard read(UInt32.self) == version else { return nil }
    }

    var isAtEnd: Bool { offset >= bytes.count }

    mutating func read<T: FixedWidthInteger>(_: T.Type) -> T {
        let size = MemoryLayout<T>.size
        guard isValid, offset + size <= bytes.count else { isValid = false; return 0 }
        let value = bytes.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self) }
        offset += size
        return T(littleEndian: value)
    }

    mutating func readDouble() -> Double { Double(bitPattern: read(UInt64.self)) }
    mutating func readFloat() -> Float { Float(bitPattern: read(UInt32.self)) }

    mutating func readCount() -> Int {
        var result: UInt64 = 0, shift: UInt64 = 0
        while isValid {
            guard offset < bytes.count, shift < 64 else { isValid = false; return 0 }
            let byte = bytes[offset]
            offset += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte < 0x80 { break }
            shift += 7
        }
        // Counts are bounded by the file size; anything larger means a corrupt file.
        guard result <= UInt64(bytes.count) else { isValid = false; return 0 }
        return Int(result)
    }

    mutating func readString() -> String {
        let count = readCount()
        guard isValid, offset + count <= bytes.count else { isValid = false; return "" }
        let string = String(decoding: bytes[offset..<(offset + count)], as: UTF8.self)
        offset += count
        return string
    }
}
