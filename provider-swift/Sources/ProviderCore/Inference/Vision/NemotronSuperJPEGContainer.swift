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
    /// Bytes from SOI through the primary image's EOI: all a decoder needs.
    let primaryLength: Int

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
        var progression: ScanProgression?
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
                guard scans > 0, progression?.isComplete == true else { throw Failure.invalidHeader }
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
                let parsed = try parseFrame(payload)
                frame = parsed
                progression = ScanProgression(components: parsed.components.map(\.id), progressive: marker == 0xc2)
            case 0xda:
                guard progression != nil else { throw Failure.invalidHeader }
                try progression?.admit(payload)
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
        return Self(width: frame.width, height: frame.height, colorModel: model, exif: exif, xmp: xmp,
                    primaryLength: position)
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

    /// The scans' spectral selection (Ss, Se) and successive approximation
    /// (Ah, Al) per component and coefficient, as ITU T.81 requires them.
    /// libjpeg-turbo tolerates scans that decode coefficients again (warning
    /// at most), and ImageIO's decode cannot be cancelled, so they are refused:
    /// a sequential frame codes each component in exactly one full-band scan;
    /// a progressive DC scan has Ss = Se = 0 and an AC scan one component and
    /// 1 <= Ss <= Se <= 63; a coefficient's first scan has Ah = 0 and Al <= 13,
    /// and each later one refines the previous Al by one bit (Ah = previous Al,
    /// Al = Ah - 1). No coefficient is decoded more than 14 times.
    private struct ScanProgression {
        private let components: [UInt8]
        private let progressive: Bool
        /// 64 coefficients per component: -1 before their first scan, then the latest Al.
        private var bits: [Int8]

        init(components: [UInt8], progressive: Bool) {
            self.components = components
            self.progressive = progressive
            bits = Array(repeating: -1, count: components.count * 64)
        }

        /// A sequential frame has coded every component.
        var isComplete: Bool { progressive || !bits.contains(-1) }

        mutating func admit(_ payload: UnsafeRawBufferPointer) throws {
            typealias Failure = NemotronSuperImageDecode.Failure
            guard let count = payload.first.map(Int.init), (1...4).contains(count),
                  payload.count == 1 + 2 * count + 3 else { throw Failure.invalidHeader }
            let ids = (0..<count).map { payload[1 + 2 * $0] }
            let indices = ids.compactMap { components.firstIndex(of: $0) }
            guard Set(ids).count == count, indices.count == count else { throw Failure.invalidHeader }
            let start = Int(payload[2 * count + 1]), end = Int(payload[2 * count + 2])
            let high = Int(payload[2 * count + 3] >> 4), low = Int(payload[2 * count + 3] & 15)
            if progressive {
                let band = start == 0 ? end == 0 : start <= end && end <= 63 && count == 1
                guard band, low <= 13, high == 0 || low == high - 1 else { throw Failure.invalidHeader }
            } else {
                guard start == 0, end == 63, high == 0, low == 0 else { throw Failure.invalidHeader }
            }
            for component in indices {
                for coefficient in start...end {
                    let index = component * 64 + coefficient
                    guard high == 0 ? bits[index] < 0 : Int(bits[index]) == high else { throw Failure.invalidHeader }
                    bits[index] = Int8(low)
                }
            }
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
