// Copyright © 2026 Eigen Labs.
import Foundation

/// Orientation semantics of the reference loader: transformers `load_image`
/// calls Pillow `ImageOps.exif_transpose` before `convert("RGB")`. Pillow
/// reads the IFD0 Orientation tag and, only when that tag is absent, the first
/// `tiff:Orientation(="|>)([0-9])` match in the XMP packet. Values outside
/// 2...8 leave the raster unchanged.
enum NemotronSuperImageOrientation {
    static func resolve(exif: Data?, xmp: Data?) throws -> Int {
        let tag = try exif.flatMap { try exifOrientation($0) } ?? xmp.flatMap(xmpOrientation)
        guard let tag, (2...8).contains(tag) else { return 1 }
        return tag
    }

    /// Field type -> unit size, as Pillow's TIFF `_load_dispatch` table.
    private static let unitSizes: [Int: Int] = [1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 6: 1, 7: 1, 8: 2,
                                                9: 4, 10: 8, 11: 4, 12: 8, 13: 4, 16: 8]

    /// Mirrors `Image.Exif.load` plus `ImageFileDirectory_v2.load` for IFD0:
    /// a truncated directory keeps the entries read before the truncation, an
    /// unknown field type is skipped, and the last duplicate entry wins.
    /// Orientation fields other than SHORT/LONG are rejected rather than
    /// reproducing Pillow's per-type coercions.
    static func exifOrientation(_ payload: Data) throws -> Int? {
        let marker = Data("Exif".utf8) + Data([0, 0])
        var start = payload.startIndex
        while payload[start...].starts(with: marker) { start += marker.count }
        let tiff = payload[start...]
        guard !tiff.isEmpty else { return nil }
        guard tiff.count >= 8 else { throw NemotronSuperImageDecode.Failure.invalidHeader }
        let little: Bool
        switch Array(tiff.prefix(4)) {
        case [0x49, 0x49, 0x2a, 0x00]: little = true
        case [0x4d, 0x4d, 0x00, 0x2a]: little = false
        default: throw NemotronSuperImageDecode.Failure.unsupportedEncoding
        }
        func integer(_ offset: Int, _ width: Int) -> Int? {
            guard offset >= 0, offset <= tiff.count - width else { return nil }
            let base = tiff.startIndex + offset
            return (0..<width).reduce(0) { value, index in
                (value << 8) | Int(tiff[base + (little ? width - 1 - index : index)])
            }
        }
        guard let directory = integer(4, 4), let count = integer(directory, 2) else { return nil }
        var orientation: Int?
        for entry in 0..<count {
            let offset = directory + 2 + entry * 12
            guard offset <= tiff.count - 12, let tag = integer(offset, 2),
                  let type = integer(offset + 2, 2), let values = integer(offset + 4, 4),
                  let field = integer(offset + 8, 4) else { break }
            guard let unit = unitSizes[type] else { continue }
            let size = values * unit
            // Pillow aborts the whole directory on a short out-of-line read.
            if size > 4, field > tiff.count - size { break }
            guard size > 0, tag == 0x0112 else { continue }
            guard type == 3 || type == 4 else { throw NemotronSuperImageDecode.Failure.unsupportedEncoding }
            // Pillow keeps the first value of an over-long Orientation field.
            orientation = integer(size > 4 ? field : offset + 8, unit)
        }
        return orientation
    }

    static func xmpOrientation(_ packet: Data) -> Int? {
        let key = Data("tiff:Orientation".utf8)
        var searchStart = packet.startIndex
        while let match = packet.range(of: key, in: searchStart..<packet.endIndex) {
            let rest = packet[match.upperBound...]
            var digit: Data.Index?
            if rest.first == UInt8(ascii: ">") {
                digit = rest.startIndex + 1
            } else if rest.starts(with: [UInt8(ascii: "="), UInt8(ascii: "\"")]) {
                digit = rest.startIndex + 2
            }
            if let digit, digit < packet.endIndex,
               (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(packet[digit]) {
                return Int(packet[digit] - UInt8(ascii: "0"))
            }
            searchStart = match.lowerBound + 1
        }
        return nil
    }
}

/// Writes RGB8 source rows directly at their EXIF-transposed destination, so
/// no second full-size raster is needed. Destination pixel = base(y) + x * step.
struct NemotronSuperOrientedRGBWriter {
    let sourceWidth: Int
    let sourceHeight: Int
    let orientation: Int
    private(set) var rgb: [UInt8]

    /// Callers bound `sourceWidth * sourceHeight` before constructing a writer.
    init(sourceWidth: Int, sourceHeight: Int, orientation: Int) {
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
        self.orientation = orientation
        rgb = [UInt8](repeating: 0, count: sourceWidth * sourceHeight * 3)
    }

    var width: Int { orientation >= 5 ? sourceHeight : sourceWidth }
    var height: Int { orientation >= 5 ? sourceWidth : sourceHeight }

    /// Pillow `Image.transpose` methods selected by `exif_transpose`.
    private func placement(row y: Int) -> (base: Int, step: Int) {
        let w = sourceWidth, h = sourceHeight
        switch orientation {
        case 2: return (y * w + w - 1, -1)
        case 3: return ((h - 1 - y) * w + w - 1, -1)
        case 4: return ((h - 1 - y) * w, 1)
        case 5: return (y, h)
        case 6: return (h - 1 - y, h)
        case 7: return ((w - 1) * h + h - 1 - y, -h)
        case 8: return ((w - 1) * h + y, -h)
        default: return (y * w, 1)
        }
    }

    /// Stores `count` packed RGB pixels of source row `y` at source columns
    /// `firstColumn + i * columnStep` (Adam7 passes use a column step).
    mutating func store(_ pixels: UnsafePointer<UInt8>, count: Int, row y: Int,
                        firstColumn: Int = 0, columnStep: Int = 1) throws {
        guard count > 0 else { return }
        guard y >= 0, y < sourceHeight, firstColumn >= 0, columnStep > 0,
              firstColumn + (count - 1) * columnStep < sourceWidth
        else { throw NemotronSuperImageDecode.Failure.invalidRaster }
        let (base, step) = placement(row: y)
        let first = base + firstColumn * step, stride = columnStep * step
        let last = first + (count - 1) * stride, total = sourceWidth * sourceHeight
        // An affine index sequence stays in range when both endpoints do.
        guard first >= 0, first < total, last >= 0, last < total else {
            throw NemotronSuperImageDecode.Failure.invalidRaster
        }
        rgb.withUnsafeMutableBufferPointer { output in
            let out = output.baseAddress!
            if stride == 1 { return (out + first * 3).update(from: pixels, count: count * 3) }
            var destination = first * 3
            for index in 0..<count {
                out[destination] = pixels[index * 3]
                out[destination + 1] = pixels[index * 3 + 1]
                out[destination + 2] = pixels[index * 3 + 2]
                destination += stride * 3
            }
        }
    }
}
