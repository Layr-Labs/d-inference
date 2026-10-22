// Copyright © 2026 Eigen Labs.
import Foundation

/// JPEG marker structure of the primary image through its EOI. Bytes after
/// that EOI (MPO frames, vendor trailers) are ignored, as Pillow decodes frame 0.
/// Only 8-bit Huffman baseline, extended-sequential and progressive frames
/// are admitted, with colour interpretations on which libjpeg-turbo (Pillow)
/// and ImageIO agree. Metadata is read only before the first SOS, as Pillow.
struct NemotronSuperJPEGContainer {
    enum ColorModel: Equatable { case gray, yCbCr, rgb, cmyk }

    let width: Int
    let height: Int
    let colorModel: ColorModel
    /// Pillow 12 concatenates later `Exif` APP1 payloads onto the first.
    let exif: Data?
    /// The last XMP APP1 packet, as Pillow's `info["xmp"]`.
    let xmp: Data?

    private struct Component { let id: UInt8, horizontal: Int, vertical: Int }

    /// Hardening beyond the reference: libjpeg-turbo advises a scan limit for
    /// untrusted progressive files, and ImageIO's decode cannot be cancelled.
    static let maximumScans = 500

    static func parse(_ bytes: UnsafeRawBufferPointer) throws -> Self {
        typealias Failure = NemotronSuperImageDecode.Failure
        guard bytes.count >= 4, bytes[0] == 0xff, bytes[1] == 0xd8, bytes[2] == 0xff else {
            throw Failure.unsupportedEncoding
        }
        var frame: (width: Int, height: Int, components: [Component])?
        var jfif = false, adobeTransform: UInt8?
        var exif: Data?, xmp: Data?
        var scans = 0, position = 2
        markers: while true {
            guard position < bytes.count, bytes[position] == 0xff else { throw Failure.invalidHeader }
            while position < bytes.count, bytes[position] == 0xff { position += 1 }
            guard position < bytes.count else { throw Failure.invalidHeader }
            let marker = bytes[position]
            position += 1
            switch marker {
            case 0xd9:  // EOI
                guard scans > 0 else { throw Failure.invalidHeader }
                break markers
            case 0x00...0xbf, 0xd0...0xd8:
                // Stuffing, TEM, reserved, RSTn outside a scan, or a second SOI.
                throw Failure.invalidHeader
            case 0xc3, 0xc5...0xcf, 0xdc, 0xde, 0xdf, 0xf0...0xfd:
                // Lossless, hierarchical, arithmetic, DNL and extension markers.
                throw Failure.unsupportedEncoding
            default:
                break
            }
            guard position <= bytes.count - 2 else { throw Failure.invalidHeader }
            let length = Int(bytes[position]) << 8 | Int(bytes[position + 1])
            guard length >= 2, length <= bytes.count - position else { throw Failure.invalidHeader }
            let payload = UnsafeRawBufferPointer(rebasing: bytes[(position + 2)..<(position + length)])
            position += length
            switch marker {
            case 0xc0, 0xc1, 0xc2:
                guard frame == nil, scans == 0 else { throw Failure.invalidHeader }
                frame = try parseFrame(payload)
            case 0xda:
                guard let frame else { throw Failure.invalidHeader }
                try validateScan(payload, frame.components)
                scans += 1
                guard scans <= maximumScans else { throw Failure.unsupportedEncoding }
                position = try entropyEnd(bytes, from: position)
            case 0xe0 where scans == 0:
                // libjpeg's saw_JFIF_marker test (APP0_DATA_LEN = 14).
                if payload.count >= 14, payload.starts(with: Array("JFIF".utf8) + [0]) { jfif = true }
            case 0xe1 where scans == 0:
                let exifMarker = Array("Exif".utf8) + [0, 0]
                let xmpMarker = Array("http://ns.adobe.com/xap/1.0/".utf8) + [0]
                if payload.starts(with: exifMarker) {
                    if exif == nil {
                        exif = Data(payload)
                    } else {
                        exif?.append(contentsOf: payload.dropFirst(exifMarker.count))
                    }
                } else if payload.starts(with: xmpMarker) {
                    xmp = Data(payload.dropFirst(xmpMarker.count))
                }
            case 0xee where scans == 0:
                // libjpeg's saw_Adobe_marker test (APP14_DATA_LEN = 12).
                if payload.count >= 12, payload.starts(with: Array("Adobe".utf8)) { adobeTransform = payload[11] }
            default:
                break  // DHT, DQT, DRI, COM and other APPn segments.
            }
        }
        guard let frame else { throw Failure.invalidHeader }
        let model = try colorModel(frame.components, jfif: jfif, adobeTransform: adobeTransform)
        return Self(width: frame.width, height: frame.height, colorModel: model, exif: exif, xmp: xmp)
    }

    private static func parseFrame(_ payload: UnsafeRawBufferPointer) throws
        -> (width: Int, height: Int, components: [Component]) {
        typealias Failure = NemotronSuperImageDecode.Failure
        guard payload.count >= 6 else { throw Failure.invalidHeader }
        let count = Int(payload[5])
        guard payload.count == 6 + 3 * count else { throw Failure.invalidHeader }
        let height = Int(payload[1]) << 8 | Int(payload[2])
        let width = Int(payload[3]) << 8 | Int(payload[4])
        // 12-bit precision, DNL-defined height and 2-component frames are refused, as by Pillow.
        guard payload[0] == 8, height > 0, [1, 3, 4].contains(count) else { throw Failure.unsupportedEncoding }
        guard width > 0 else { throw Failure.invalidHeader }
        // libjpeg-turbo's JPEG_MAX_DIMENSION.
        guard width <= 65500, height <= 65500 else { throw Failure.sizeLimit }
        let components = try (0..<count).map { index -> Component in
            let base = 6 + index * 3
            let horizontal = Int(payload[base + 1] >> 4), vertical = Int(payload[base + 1] & 15)
            guard (1...4).contains(horizontal), (1...4).contains(vertical), payload[base + 2] <= 3 else {
                throw Failure.invalidHeader
            }
            return Component(id: payload[base], horizontal: horizontal, vertical: vertical)
        }
        guard Set(components.map(\.id)).count == count else { throw Failure.invalidHeader }
        return (width, height, components)
    }

    private static func validateScan(_ payload: UnsafeRawBufferPointer, _ components: [Component]) throws {
        guard let count = payload.first.map(Int.init), (1...4).contains(count),
              payload.count == 1 + 2 * count + 3 else { throw NemotronSuperImageDecode.Failure.invalidHeader }
        let ids = (0..<count).map { payload[1 + 2 * $0] }
        guard Set(ids).count == count, ids.allSatisfy({ id in components.contains { $0.id == id } }) else {
            throw NemotronSuperImageDecode.Failure.invalidHeader
        }
    }

    /// Offset of the marker that ends the entropy-coded segment. Stuffed 0x00
    /// bytes and RSTn markers belong to the segment.
    private static func entropyEnd(_ bytes: UnsafeRawBufferPointer, from start: Int) throws -> Int {
        var position = start
        while position < bytes.count {
            guard let found = memchr(bytes.baseAddress! + position, 0xff, bytes.count - position) else { break }
            let index = bytes.baseAddress!.distance(to: UnsafeRawPointer(found))
            guard index + 1 < bytes.count else { break }
            switch bytes[index + 1] {
            case 0x00, 0xd0...0xd7: position = index + 2
            case 0xff: position = index + 1
            default: return index
            }
        }
        throw NemotronSuperImageDecode.Failure.invalidHeader
    }

    /// libjpeg-turbo `default_decompress_parms`, restricted to the cases that
    /// ImageIO decodes the same way. ImageIO, unlike libjpeg, lets an Adobe
    /// transform override JFIF and does not honour 'R','G','B' component IDs;
    /// YCCK has no qualified fixture. Those inputs are refused.
    private static func colorModel(_ components: [Component], jfif: Bool,
                                   adobeTransform: UInt8?) throws -> ColorModel {
        typealias Failure = NemotronSuperImageDecode.Failure
        let model: ColorModel
        switch components.count {
        case 1:
            return .gray
        case 3:
            let rgbIDs = components.map(\.id) == [82, 71, 66]
            switch (jfif, adobeTransform) {
            case (_, nil), (_, 1): model = .yCbCr
            case (false, 0): model = .rgb
            default: throw Failure.unsupportedEncoding
            }
            if rgbIDs, model != .rgb { throw Failure.unsupportedEncoding }
        default:
            guard !jfif, adobeTransform == nil || adobeTransform == 0 else { throw Failure.unsupportedEncoding }
            model = .cmyk
        }
        // Chroma upsampling is qualified for full, 2x1 and 2x2 luma sampling only.
        let luma = (components[0].horizontal, components[0].vertical)
        let others = components.dropFirst().allSatisfy { $0.horizontal == 1 && $0.vertical == 1 }
        guard others, luma == (1, 1) || (model == .yCbCr && (luma == (2, 1) || luma == (2, 2))) else {
            throw Failure.unsupportedEncoding
        }
        return model
    }
}
