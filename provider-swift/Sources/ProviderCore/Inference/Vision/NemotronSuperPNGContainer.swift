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

    var channels: Int {
        switch colorType {
        case 2: return 3
        case 4: return 2
        case 6: return 4
        default: return 1
        }
    }

    /// Chunk types with specific handling; any other ancillary chunk is ignored.
    enum ChunkType: Int {
        case header = 0x4948_4452  // IHDR
        case palette = 0x504c_5445  // PLTE
        case transparency = 0x7452_4e53  // tRNS
        case imageData = 0x4944_4154  // IDAT
        case end = 0x4945_4e44  // IEND
        case exif = 0x6558_4966  // eXIf
        case text = 0x7445_5874  // tEXt
        case compressedText = 0x7a54_5874  // zTXt
        case internationalText = 0x6954_5874  // iTXt
        case animationControl = 0x6163_544c  // acTL
        case frameControl = 0x6663_544c  // fcTL
        case frameData = 0x6664_4154  // fdAT
        case gamma = 0x6741_4d41  // gAMA
        case standardRGB = 0x7352_4742  // sRGB
        case physicalDimensions = 0x7048_5973  // pHYs
        case chromaticities = 0x6348_524d  // cHRM
        case iccProfile = 0x6943_4350  // iCCP
    }

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
        var exif: Data?, xmp: Data?, rawProfile = false, profile = false
        var text = NemotronSuperPNGText()
        var animation = false, frameSequence = 0, framePassedData = false
        var offset = 8, chunks = 0, ended = false
        while !ended {
            chunks += 1
            if chunks.isMultiple(of: 1024) { try Task.checkCancellation() }
            guard chunks <= maximumChunks else { throw Failure.sizeLimit }
            guard offset <= bytes.count - 12 else { throw Failure.invalidHeader }
            let length = word(offset), type = ChunkType(rawValue: word(offset + 4))
            guard length <= 0x7fff_ffff, length <= bytes.count - offset - 12,
                  (0..<4).allSatisfy({ isLetter(bytes[offset + 4 + $0]) }) else { throw Failure.invalidHeader }
            let body = (offset + 8)..<(offset + 8 + length)
            let crc = crc32(0, bytes.baseAddress!.advanced(by: offset + 4)
                .assumingMemoryBound(to: Bytef.self), UInt32(length + 4))
            guard UInt(crc) == UInt(word(body.upperBound)) else { throw Failure.invalidHeader }
            guard header != nil || type == .header else { throw Failure.invalidHeader }
            if !imageData.isEmpty, type != .imageData { dataEnded = true }
            guard let type else {
                // Unknown ancillary chunks never change Pillow's pixel values.
                guard bytes[offset + 4] & 0x20 != 0 else { throw Failure.unsupportedEncoding }
                offset = body.upperBound + 4
                continue
            }
            // Pillow stops reading frame-0 metadata at the next APNG frame.
            let metadataVisible = !framePassedData
            switch type {
            case .header:
                guard header == nil, length == 13 else { throw Failure.invalidHeader }
                let width = word(body.lowerBound), height = word(body.lowerBound + 4)
                let depth = Int(bytes[body.lowerBound + 8]), colour = Int(bytes[body.lowerBound + 9])
                guard (1...0x7fff_ffff).contains(width), (1...0x7fff_ffff).contains(height),
                      validDepths[colour]?.contains(depth) == true,
                      bytes[body.lowerBound + 10] == 0, bytes[body.lowerBound + 11] == 0,
                      bytes[body.lowerBound + 12] <= 1 else { throw Failure.invalidHeader }
                header = (width, height, depth, colour, bytes[body.lowerBound + 12] == 1)
            case .palette:
                let entries = length / 3
                guard let header, palette == nil, imageData.isEmpty, length % 3 == 0,
                      (1...256).contains(entries), header.type != 0, header.type != 4,
                      header.type != 3 || entries <= 1 << header.depth else { throw Failure.invalidHeader }
                palette = header.type == 3 ? Array(bytes[body]) : []
            case .transparency:  // Pillow's RGB conversion ignores transparency.
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
            case .imageData:
                guard let header, !dataEnded, header.type != 3 || palette?.isEmpty == false else {
                    throw Failure.invalidHeader
                }
                imageData.append(body)
            case .end:
                guard !imageData.isEmpty, length == 0 else { throw Failure.invalidHeader }
                ended = true
            case .exif:
                guard exif == nil else { throw Failure.invalidHeader }
                guard metadataVisible else { throw Failure.unsupportedEncoding }
                exif = Data(bytes[body])
            case .text, .compressedText, .internationalText:
                switch try text.read(type, UnsafeRawBufferPointer(rebasing: bytes[body])) {
                case .ignored: break
                case .rawProfile:
                    guard metadataVisible else { throw Failure.unsupportedEncoding }
                    rawProfile = true
                case .xmp(let packet):
                    guard xmp == nil, metadataVisible else { throw Failure.unsupportedEncoding }
                    xmp = packet
                }
            case .animationControl:
                guard !animation, imageData.isEmpty, length == 8 else { throw Failure.invalidHeader }
                animation = true
            case .frameControl, .frameData:  // Frame 0 is the IDAT image.
                guard animation, length >= 4, word(body.lowerBound) == frameSequence else {
                    throw Failure.invalidHeader
                }
                frameSequence += 1
                if type == .frameData {
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
            case .gamma: guard length == 4 else { throw Failure.invalidHeader }
            case .standardRGB: guard length == 1 else { throw Failure.invalidHeader }
            case .physicalDimensions: guard length == 9 else { throw Failure.invalidHeader }
            case .chromaticities: guard length == 32 else { throw Failure.invalidHeader }
            case .iccProfile:
                // At most one profile, as the PNG specification requires, bounds
                // inflate work; Pillow would read every copy.
                guard !profile else { throw Failure.invalidHeader }
                profile = true
                try NemotronSuperPNGText.checkProfile(UnsafeRawBufferPointer(rebasing: bytes[body]))
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
}
