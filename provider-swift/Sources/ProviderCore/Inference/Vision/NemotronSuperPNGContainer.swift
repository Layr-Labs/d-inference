// Copyright © 2026 Eigen Labs.
import Foundation
import zlib

/// PNG chunk structure as Pillow's `PngImagePlugin` reads it for frame 0, with
/// stricter fail-closed checks: every CRC, IHDR combination, PLTE/tRNS shape,
/// consecutive IDAT chunks, exact end after IEND and no unknown critical chunk.
/// Nothing here allocates in proportion to the declared raster.
struct NemotronSuperPNGContainer {
    let width: Int
    let height: Int
    let bitDepth: Int
    let colorType: Int
    let interlaced: Bool
    /// Packed RGB PLTE entries for colour type 3 only.
    let palette: [UInt8]
    /// IDAT payload ranges in the encoded buffer, in file order.
    let imageData: [Range<Int>]
    let exif: Data?
    let xmp: Data?

    var channels: Int { [0: 1, 2: 3, 3: 1, 4: 2, 6: 4][colorType] ?? 0 }

    /// Pillow `MAX_TEXT_CHUNK`: a larger compressed text chunk fails to open.
    static let maximumTextBytes = 1024 * 1024
    private static let maximumChunks = 65536

    private static let validDepths: [Int: Set<Int>] = [
        0: [1, 2, 4, 8, 16], 2: [8, 16], 3: [1, 2, 4, 8], 4: [8, 16], 6: [8, 16],
    ]

    static func parse(_ bytes: UnsafeRawBufferPointer) throws -> Self {
        let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
        guard bytes.count >= 8, bytes.prefix(8).elementsEqual(signature) else {
            throw NemotronSuperImageDecode.Failure.unsupportedEncoding
        }
        func word(_ offset: Int) -> Int {
            (0..<4).reduce(0) { ($0 << 8) | Int(bytes[offset + $1]) }
        }
        typealias Failure = NemotronSuperImageDecode.Failure
        var header: (width: Int, height: Int, depth: Int, type: Int, interlaced: Bool)?
        var palette: [UInt8]?, transparency = false
        var imageData: [Range<Int>] = [], dataEnded = false
        var exif: Data?, xmp: Data?, rawProfile = false
        var animation = false, frameSequence = 0, framePassedData = false
        var offset = 8, chunks = 0, ended = false
        while !ended {
            chunks += 1
            if chunks.isMultiple(of: 1024) { try Task.checkCancellation() }
            guard chunks <= maximumChunks else { throw Failure.sizeLimit }
            guard offset <= bytes.count - 12 else { throw Failure.invalidHeader }
            let length = word(offset), type = word(offset + 4)
            guard length <= 0x7fff_ffff, length <= bytes.count - offset - 12,
                  (0..<4).allSatisfy({ isLetter(bytes[offset + 4 + $0]) }) else { throw Failure.invalidHeader }
            let body = (offset + 8)..<(offset + 8 + length)
            let crc = crc32(0, bytes.baseAddress!.advanced(by: offset + 4)
                .assumingMemoryBound(to: Bytef.self), UInt32(length + 4))
            guard UInt(crc) == UInt(word(body.upperBound)) else { throw Failure.invalidHeader }
            guard header != nil || type == 0x4948_4452 else { throw Failure.invalidHeader }
            if !imageData.isEmpty, type != 0x4944_4154 { dataEnded = true }
            // Pillow stops reading frame-0 metadata at the next APNG frame.
            let metadataVisible = !framePassedData
            switch type {
            case 0x4948_4452:  // IHDR
                guard header == nil, length == 13 else { throw Failure.invalidHeader }
                let width = word(body.lowerBound), height = word(body.lowerBound + 4)
                let depth = Int(bytes[body.lowerBound + 8]), colour = Int(bytes[body.lowerBound + 9])
                guard (1...0x7fff_ffff).contains(width), (1...0x7fff_ffff).contains(height),
                      validDepths[colour]?.contains(depth) == true,
                      bytes[body.lowerBound + 10] == 0, bytes[body.lowerBound + 11] == 0,
                      bytes[body.lowerBound + 12] <= 1 else { throw Failure.invalidHeader }
                header = (width, height, depth, colour, bytes[body.lowerBound + 12] == 1)
            case 0x504c_5445:  // PLTE
                let entries = length / 3
                guard let header, palette == nil, imageData.isEmpty, length % 3 == 0,
                      (1...256).contains(entries), header.type != 0, header.type != 4,
                      header.type != 3 || entries <= 1 << header.depth else { throw Failure.invalidHeader }
                palette = header.type == 3 ? Array(bytes[body]) : []
            case 0x7452_4e53:  // tRNS: Pillow's RGB conversion ignores transparency.
                guard let header, !transparency, imageData.isEmpty else { throw Failure.invalidHeader }
                switch header.type {
                case 0: guard length == 2 else { throw Failure.invalidHeader }
                case 2: guard length == 6 else { throw Failure.invalidHeader }
                case 3:
                    guard let palette, !palette.isEmpty, length <= palette.count / 3 else {
                        throw Failure.invalidHeader
                    }
                default: throw Failure.invalidHeader
                }
                transparency = true
            case 0x4944_4154:  // IDAT
                guard let header, !dataEnded, header.type != 3 || palette?.isEmpty == false else {
                    throw Failure.invalidHeader
                }
                imageData.append(body)
            case 0x4945_4e44:  // IEND
                guard !imageData.isEmpty, length == 0 else { throw Failure.invalidHeader }
                ended = true
            case 0x6558_4966:  // eXIf
                guard exif == nil else { throw Failure.invalidHeader }
                guard metadataVisible else { throw Failure.unsupportedEncoding }
                exif = Data(bytes[body])
            case 0x7445_5874, 0x7a54_5874, 0x6954_5874:  // tEXt, zTXt, iTXt
                switch try text(type: type, bytes: UnsafeRawBufferPointer(rebasing: bytes[body])) {
                case .ignored: break
                case .rawProfile:
                    guard metadataVisible else { throw Failure.unsupportedEncoding }
                    rawProfile = true
                case .xmp(let packet):
                    guard xmp == nil, metadataVisible else { throw Failure.unsupportedEncoding }
                    xmp = packet
                }
            case 0x6163_544c:  // acTL
                guard !animation, imageData.isEmpty, length == 8 else { throw Failure.invalidHeader }
                animation = true
            case 0x6663_544c, 0x6664_4154:  // fcTL, fdAT: frame 0 is the IDAT image.
                guard animation, length >= 4, word(body.lowerBound) == frameSequence else {
                    throw Failure.invalidHeader
                }
                frameSequence += 1
                if type == 0x6664_4154 {
                    guard dataEnded else { throw Failure.invalidHeader }
                } else if imageData.isEmpty {
                    // An fcTL before IDAT makes IDAT the first frame; it must
                    // cover the canvas or Pillow would decode a sub-rectangle.
                    guard let header, length == 26 else { throw Failure.invalidHeader }
                    guard word(body.lowerBound + 4) == header.width, word(body.lowerBound + 8) == header.height,
                          word(body.lowerBound + 12) == 0, word(body.lowerBound + 16) == 0
                    else { throw Failure.unsupportedEncoding }
                } else {
                    guard length == 26 else { throw Failure.invalidHeader }
                    framePassedData = true
                }
            case 0x6741_4d41: guard length == 4 else { throw Failure.invalidHeader }  // gAMA
            case 0x7352_4742: guard length == 1 else { throw Failure.invalidHeader }  // sRGB
            case 0x7048_5973: guard length == 9 else { throw Failure.invalidHeader }  // pHYs
            case 0x6348_524d: guard length == 32 else { throw Failure.invalidHeader }  // cHRM
            case 0x6943_4350:  // iCCP: Pillow rejects any non-zlib method.
                let name = bytes[body].prefix(81).firstIndex(of: 0)
                guard let name, name > body.lowerBound, name + 1 < body.upperBound,
                      bytes[name + 1] == 0 else { throw Failure.invalidHeader }
            default:
                // Ancillary chunks never change Pillow's pixel values.
                guard bytes[offset + 4] & 0x20 != 0 else { throw Failure.unsupportedEncoding }
            }
            offset = body.upperBound + 4
        }
        guard let header, offset == bytes.count else { throw Failure.invalidHeader }
        // Pillow derives EXIF from this text only when no eXIf chunk exists.
        guard !rawProfile || exif != nil else { throw Failure.unsupportedEncoding }
        return Self(width: header.width, height: header.height, bitDepth: header.depth,
                    colorType: header.type, interlaced: header.interlaced, palette: palette ?? [],
                    imageData: imageData, exif: exif, xmp: xmp)
    }

    private static func isLetter(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte)
    }

    private enum Text { case ignored, rawProfile, xmp(Data) }

    /// Only keywords that Pillow's EXIF/XMP lookup reads can change pixels.
    /// Text it would store with a different type under those keys is refused.
    private static func text(type: Int, bytes: UnsafeRawBufferPointer) throws -> Text {
        typealias Failure = NemotronSuperImageDecode.Failure
        let separator = bytes.firstIndex(of: 0)
        let keyword = String(decoding: bytes[..<(separator ?? bytes.count)], as: UTF8.self)
        let value = separator.map { bytes.index(after: $0) } ?? bytes.count
        if type == 0x7a54_5874, value < bytes.count, bytes[value] != 0 {
            // Pillow raises for any zTXt with a non-zlib compression method.
            throw Failure.invalidHeader
        }
        switch keyword {
        case "XML:com.adobe.xmp": break
        case "Raw profile type exif": return .rawProfile
        case "exif", "xmp": throw Failure.unsupportedEncoding
        default: return .ignored
        }
        switch type {
        case 0x7445_5874:  // tEXt
            return .xmp(Data(bytes[value...]))
        case 0x7a54_5874:  // zTXt
            guard value < bytes.count else { return .xmp(Data()) }
            return .xmp(try NemotronSuperInflater.inflateAll(
                UnsafeRawBufferPointer(rebasing: bytes[(value + 1)...]), limit: maximumTextBytes))
        default:  // iTXt; Pillow ignores the malformed or non-zlib forms refused here.
            guard value + 2 <= bytes.count else { throw Failure.unsupportedEncoding }
            let compressed = bytes[value] != 0
            guard !compressed || bytes[value + 1] == 0,
                  let language = bytes[(value + 2)...].firstIndex(of: 0),
                  let translated = bytes[(language + 1)...].firstIndex(of: 0) else {
                throw Failure.unsupportedEncoding
            }
            let text = UnsafeRawBufferPointer(rebasing: bytes[(translated + 1)...])
            guard compressed else { return .xmp(Data(text)) }
            return .xmp(try NemotronSuperInflater.inflateAll(text, limit: maximumTextBytes))
        }
    }
}
