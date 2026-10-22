// Copyright © 2026 Eigen Labs.
import Foundation

/// Streams IDAT rows (inflate, unfilter, Adam7) into RGB8 with Pillow's PNG
/// rawmodes followed by `convert("RGB")`:
/// - gray 1/2/4 bits scale to 0...255 (x255, x85, x17); 8 bits replicate;
/// - gray 16 bits opens as mode `I;16`, whose RGB conversion clips to 255;
/// - every other 16-bit sample keeps its most significant byte;
/// - palette indices expand through PLTE, and tRNS is ignored;
/// - gray+alpha and RGBA drop alpha without compositing.
/// Colour management chunks (gAMA, cHRM, sRGB, iCCP) are ignored, as in Pillow.
enum NemotronSuperPNGRaster {
    private static let adam7: [(x: Int, y: Int, dx: Int, dy: Int)] = [
        (0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4), (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2),
    ]

    /// `bytes` must be the buffer `png` was parsed from: its IDAT ranges index it.
    static func decode(_ bytes: UnsafeRawBufferPointer, _ png: NemotronSuperPNGContainer,
                       orientation: Int) throws -> NemotronSuperOrientedRGBWriter {
        let segments = png.imageData.map { UnsafeRawBufferPointer(rebasing: bytes[$0]) }
        let inflater = try NemotronSuperInflater(segments: segments)
        var writer = NemotronSuperOrientedRGBWriter(
            sourceWidth: png.width, sourceHeight: png.height, orientation: orientation)
        let bitsPerPixel = png.channels * png.bitDepth
        let bytesPerPixel = max(1, bitsPerPixel / 8)
        // 8-bit RGB rows are already packed RGB8.
        let packed = png.colorType == 2 && png.bitDepth == 8
        let maximumRowBytes = (png.width * bitsPerPixel + 7) / 8
        // Two filtered rows (with filter byte) plus one RGB8 output row.
        let scratch = UnsafeMutablePointer<UInt8>.allocate(capacity: 2 * (maximumRowBytes + 1) + png.width * 3)
        defer { scratch.deallocate() }
        var previous = scratch, current = scratch + maximumRowBytes + 1
        let rgb = scratch + 2 * (maximumRowBytes + 1)
        for pass in png.interlaced ? adam7 : [(0, 0, 1, 1)] {
            guard png.width > pass.x, png.height > pass.y else { continue }
            let columns = (png.width - pass.x + pass.dx - 1) / pass.dx
            let rows = (png.height - pass.y + pass.dy - 1) / pass.dy
            let rowBytes = (columns * bitsPerPixel + 7) / 8
            // Each pass is filtered as its own image: its first prior row is zero.
            previous.initialize(repeating: 0, count: rowBytes + 1)
            for row in 0..<rows {
                if row.isMultiple(of: 64) { try Task.checkCancellation() }
                try inflater.read(into: current, count: rowBytes + 1)
                try unfilter(current[0], row: current + 1, previous: previous + 1,
                             count: rowBytes, bytesPerPixel: bytesPerPixel)
                if !packed { try expand(current + 1, columns: columns, png: png, into: rgb) }
                try writer.store(packed ? current + 1 : rgb, count: columns, row: pass.y + row * pass.dy,
                                 firstColumn: pass.x, columnStep: pass.dx)
                swap(&previous, &current)
            }
        }
        try inflater.finish()
        return writer
    }

    private static func unfilter(_ type: UInt8, row: UnsafeMutablePointer<UInt8>,
                                 previous: UnsafePointer<UInt8>, count: Int, bytesPerPixel: Int) throws {
        // The first pixel has no left neighbour (a = c = 0); later bytes do.
        let stride = bytesPerPixel
        let lead = min(stride, count)
        switch type {
        case 0: return
        case 1:
            for i in Swift.stride(from: stride, to: count, by: 1) { row[i] &+= row[i - stride] }
        case 2:
            for i in 0..<count { row[i] &+= previous[i] }
        case 3:
            for i in 0..<lead { row[i] &+= previous[i] >> 1 }
            for i in Swift.stride(from: stride, to: count, by: 1) {
                row[i] &+= UInt8((UInt16(row[i - stride]) + UInt16(previous[i])) >> 1)
            }
        case 4:
            for i in 0..<lead { row[i] &+= previous[i] }
            for i in Swift.stride(from: stride, to: count, by: 1) {
                let a = Int(row[i - stride]), b = Int(previous[i]), c = Int(previous[i - stride])
                let pa = abs(b - c), pb = abs(a - c), pc = abs(a + b - 2 * c)
                row[i] &+= UInt8(truncatingIfNeeded: pa <= pb && pa <= pc ? a : (pb <= pc ? b : c))
            }
        default: throw NemotronSuperImageDecode.Failure.invalidRaster
        }
    }

    private static func expand(_ row: UnsafePointer<UInt8>, columns: Int,
                               png: NemotronSuperPNGContainer, into rgb: UnsafeMutablePointer<UInt8>) throws {
        func put(_ x: Int, _ r: UInt8, _ g: UInt8, _ b: UInt8) {
            rgb[x * 3] = r
            rgb[x * 3 + 1] = g
            rgb[x * 3 + 2] = b
        }
        let depth = png.bitDepth
        switch (png.colorType, depth) {
        case (0, 16):
            for x in 0..<columns {
                let value = row[2 * x] == 0 ? row[2 * x + 1] : 255
                put(x, value, value, value)
            }
        case (0, 8):
            for x in 0..<columns { put(x, row[x], row[x], row[x]) }
        case (0, _):
            let scale = UInt8(255 / ((1 << depth) - 1))
            for x in 0..<columns {
                let value = packedSample(row, x, depth) * scale
                put(x, value, value, value)
            }
        case (3, _):
            let entries = png.palette.count / 3
            try png.palette.withUnsafeBufferPointer { palette in
                for x in 0..<columns {
                    let index = Int(depth == 8 ? row[x] : packedSample(row, x, depth))
                    guard index < entries else { throw NemotronSuperImageDecode.Failure.invalidRaster }
                    put(x, palette[index * 3], palette[index * 3 + 1], palette[index * 3 + 2])
                }
            }
        default:
            // Interleaved samples: keep the leading byte of each 16-bit sample.
            let sampleBytes = depth / 8, pixelBytes = png.channels * sampleBytes
            let gray = png.colorType == 4
            for x in 0..<columns {
                let base = x * pixelBytes
                if gray {
                    put(x, row[base], row[base], row[base])
                } else {
                    put(x, row[base], row[base + sampleBytes], row[base + 2 * sampleBytes])
                }
            }
        }
    }

    private static func packedSample(_ row: UnsafePointer<UInt8>, _ x: Int, _ depth: Int) -> UInt8 {
        let bit = x * depth
        return (row[bit >> 3] >> UInt8(8 - depth - (bit & 7))) & UInt8((1 << depth) - 1)
    }
}
