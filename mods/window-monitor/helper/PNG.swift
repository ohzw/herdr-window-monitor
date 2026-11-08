// Lossless RGB PNG framing.
// The capture helper already has RGB pixels and zlib; no ImageIO or image-file
// roundtrip is required to encode a frame. All large byte buffers are reused.
import Foundation

final class PNGEncoder {
    private let metrics: StageMetrics?
    private var scanlines: [UInt8] = []
    private var compressed: [UInt8] = []

    init(metrics: StageMetrics? = nil) {
        self.metrics = metrics
    }

    func encode(rgb: UnsafeRawBufferPointer, width: Int, height: Int, into out: inout [UInt8]) -> Bool {
        let rowBytes = width * 3
        let filteredSize = (rowBytes + 1) * height
        measure(.pngScanlines) {
            if scanlines.count < filteredSize { scanlines = [UInt8](repeating: 0, count: filteredSize) }
            scanlines.withUnsafeMutableBytes { dest in
                for y in 0..<height {
                    let row = y * (rowBytes + 1)
                    dest[row] = 0 // PNG filter None
                    memcpy(dest.baseAddress! + row + 1, rgb.baseAddress! + y * rowBytes, rowBytes)
                }
            }
        }
        var count = uLong(compressed.count)
        let rc = measure(.zlib) {
            let bound = Int(compressBound(uLong(filteredSize)))
            if compressed.count < bound { compressed = [UInt8](repeating: 0, count: bound) }
            count = uLong(compressed.count)
            return compressed.withUnsafeMutableBufferPointer { dest in
                scanlines.withUnsafeBufferPointer { source in
                    compress2(dest.baseAddress, &count, source.baseAddress, uLong(filteredSize), 1)
                }
            }
        }
        guard rc == Z_OK else { return false }
        measure(.pngChunksCRC) {
            out.removeAll(keepingCapacity: true)
            out.append(contentsOf: [137, 80, 78, 71, 13, 10, 26, 10])
            var ihdr: [UInt8] = []
            append32(UInt32(width), to: &ihdr)
            append32(UInt32(height), to: &ihdr)
            ihdr.append(contentsOf: [8, 2, 0, 0, 0]) // 8-bit RGB, deflate, filter, no interlace
            ihdr.withUnsafeBytes { chunk("IHDR", bytes: $0, into: &out) }
            compressed.withUnsafeBytes { chunk("IDAT", bytes: UnsafeRawBufferPointer(rebasing: $0[..<Int(count)]), into: &out) }
            chunk("IEND", bytes: UnsafeRawBufferPointer(start: nil, count: 0), into: &out)
        }
        return true
    }

    private func measure<T>(_ stage: StageMetrics.Stage, _ body: () throws -> T) rethrows -> T {
        guard let metrics else { return try body() }
        return try metrics.measure(stage, body)
    }

    private func append32(_ value: UInt32, to out: inout [UInt8]) {
        out.append(UInt8(truncatingIfNeeded: value >> 24))
        out.append(UInt8(truncatingIfNeeded: value >> 16))
        out.append(UInt8(truncatingIfNeeded: value >> 8))
        out.append(UInt8(truncatingIfNeeded: value))
    }

    private func chunk(_ name: String, bytes: UnsafeRawBufferPointer, into out: inout [UInt8]) {
        append32(UInt32(bytes.count), to: &out)
        let start = out.count
        out.append(contentsOf: name.utf8)
        out.append(contentsOf: bytes.bindMemory(to: UInt8.self))
        let crc = out.withUnsafeBytes { buffer in
            crc32(0, buffer.baseAddress!.advanced(by: start).assumingMemoryBound(to: UInt8.self), uInt(4 + bytes.count))
        }
        append32(UInt32(crc), to: &out)
    }
}
