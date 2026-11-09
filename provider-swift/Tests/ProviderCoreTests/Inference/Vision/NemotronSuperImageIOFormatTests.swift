// Copyright © 2026 Eigen Labs.
import CoreGraphics
import CryptoKit
import Foundation
import Testing
@testable import ProviderCore

/// WebP, GIF (frame 0) and BMP through ImageIO: each becomes the same RGB8
/// raster as the PNG it was made from, under the same limits, with WebP's
/// EXIF orientation; every sample layout ImageIO can hand back converts as
/// Pillow's `convert("RGB")` does.
struct NemotronSuperImageIOFormatTests {
    private typealias Decode = NemotronSuperImageDecode

    /// A PNG fixture's RGB8 raster, the source of the other encodings.
    static func raster(_ file: String) throws -> NemotronSuperImageDecode.Raster {
        try Decode.decode(NemotronSuperImageFixtures.data(file), orientation: .preserveRaster)
    }

    private static func sha256(_ bytes: [UInt8]) -> String {
        SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }

    @Test func bmpAndGIFDecodeToTheirSourceRaster() throws {
        let rgb = try Self.raster("png-rgb8.png")
        let bmp = Self.bmp(rgb)
        #expect(try Decode.inspect(bmp, orientation: .applyEXIF).format == .bmp)
        let fromBMP = try Decode.decode(bmp, orientation: .applyEXIF)
        #expect(fromBMP.width == rgb.width && fromBMP.height == rgb.height && fromBMP.rgb == rgb.rgb)
        // A palette image has at most 256 colours, so GIF keeps it exactly.
        let palette = try Self.raster("png-palette8.png")
        let gif = try Self.gif(palette)
        #expect(try Decode.inspect(gif, orientation: .applyEXIF).format == .gif)
        let fromGIF = try Decode.decode(gif, orientation: .applyEXIF)
        #expect(fromGIF.width == palette.width && fromGIF.height == palette.height && fromGIF.rgb == palette.rgb)
    }

    /// `webp-rgb8-lossless.webp` is `png-rgb8.png` through
    /// `cwebp -lossless -exact`; it decodes to Pillow's RGB8 of that PNG.
    @Test func losslessWebPDecodesToThePillowReference() throws {
        let webp = try NemotronSuperImageFixtures.data("webp-rgb8-lossless.webp")
        #expect(try Decode.inspect(webp, orientation: .applyEXIF).format == .webp)
        let decoded = try Decode.decode(webp, orientation: .applyEXIF)
        let reference = try #require(try NemotronSuperImageFixtures.cases().first { $0.name == "png-rgb8" })
        #expect(decoded.width == reference.width && decoded.height == reference.height)
        #expect(Self.sha256(decoded.rgb) == reference.rgbSha256)
    }

    /// `webp-exif6.webp` is `jpeg-exif6.jpeg` through `cwebp -metadata exif`:
    /// its `EXIF` chunk turns it as Pillow's `exif_transpose` does.
    @Test func webPOrientationComesFromItsEXIFChunk() throws {
        let webp = try NemotronSuperImageFixtures.data("webp-exif6.webp")
        let reference = try #require(try NemotronSuperImageFixtures.cases().first { $0.name == "jpeg-exif6" })
        let quote = try Decode.inspect(webp, orientation: .applyEXIF)
        #expect(quote.orientation == 6)
        #expect(quote.sourceWidth == reference.unorientedWidth && quote.sourceHeight == reference.unorientedHeight)
        let oriented = try Decode.decode(webp, orientation: .applyEXIF)
        #expect(oriented.width == reference.width && oriented.height == reference.height)
        let raw = try Decode.decode(webp, orientation: .preserveRaster)
        #expect(raw.width == reference.unorientedWidth && raw.height == reference.unorientedHeight)
    }

    @Test func webPMetadataReadsTheFirstChunksAndRefusesOverruns() throws {
        func riff(_ chunks: [(String, [UInt8])], declared: Int? = nil) -> Data {
            var body = Array("WEBP".utf8)
            for (tag, payload) in chunks {
                body += Array(tag.utf8) + Self.le32(payload.count) + payload + (payload.count % 2 == 1 ? [0] : [])
            }
            return Data(Array("RIFF".utf8) + Self.le32(declared ?? body.count) + body)
        }
        let metadata = try NemotronSuperImageIOContainer.webPMetadata(riff([
            ("VP8X", [UInt8](repeating: 0, count: 10)), ("EXIF", [1, 2, 3]), ("XMP ", [4, 5]),
            ("EXIF", [9]), ("XMP ", [9]),
        ]))
        #expect(metadata.exif == Data([1, 2, 3]) && metadata.xmp == Data([4, 5]))
        let none = try NemotronSuperImageIOContainer.webPMetadata(riff([("VP8L", [0, 0])]))
        #expect(none.exif == nil && none.xmp == nil)
        // A chunk past the RIFF payload, or a header shorter than RIFF's.
        let overrun = riff([("EXIF", [1, 2, 3, 4])], declared: 10)
        #expect(throws: Decode.Failure.invalidHeader) { try NemotronSuperImageIOContainer.webPMetadata(overrun) }
        #expect(throws: Decode.Failure.invalidHeader) {
            try NemotronSuperImageIOContainer.webPMetadata(Data("RIFF".utf8))
        }
    }

    /// The same limits as PNG and JPEG apply from the header alone.
    @Test func headerLimitsAndForeignTypesAreRefused() throws {
        let bmp = Self.bmp(try Self.raster("png-rgb8.png"))
        #expect(throws: Decode.Failure.sizeLimit) {
            try Decode.inspect(bmp, orientation: .applyEXIF, maxPixels: 37 * 23 - 1)
        }
        #expect(throws: Decode.Failure.sizeLimit) {
            try Decode.inspect(bmp, orientation: .applyEXIF, maxEncodedBytes: bmp.count - 1)
        }
        // A BMP signature over other bytes is no BMP; TIFF and HEIC stay refused.
        #expect(throws: Decode.Failure.invalidHeader) {
            try Decode.inspect(Data("BM".utf8) + Data(count: 4), orientation: .applyEXIF)
        }
        for signature in [[0x49, 0x49, 0x2a, 0x00, 8, 0, 0, 0], [0, 0, 0, 0x18] + Array("ftypheic".utf8)] as [[UInt8]] {
            #expect(throws: Decode.Failure.unsupportedEncoding) {
                try Decode.inspect(Data(signature), orientation: .applyEXIF)
            }
        }
    }

    /// Every layout ImageIO can return: read directly (gray, gray with
    /// alpha, RGB, both 32-bit byte orders, straight or premultiplied alpha,
    /// a palette) or drawn once (16-bit RGB). Alpha is dropped; premultiplied
    /// samples are divided by it first.
    @Test func everySampleLayoutConvertsAsPillow() throws {
        let rgb = CGColorSpace(name: CGColorSpace.sRGB)!, gray = CGColorSpace(name: CGColorSpace.linearGray)!
        let big = CGBitmapInfo.byteOrder32Big.rawValue, little = CGBitmapInfo.byteOrder32Little.rawValue
        typealias Case = (name: String, bytes: [UInt8], bitsPerPixel: Int, space: CGColorSpace, info: UInt32,
                          expected: [UInt8])
        let cases: [Case] = [
            ("gray", [10, 200], 8, gray, CGImageAlphaInfo.none.rawValue, [10, 10, 10, 200, 200, 200]),
            ("gray alpha premultiplied", [50, 100, 0, 0], 16, gray,
             CGImageAlphaInfo.premultipliedLast.rawValue, [128, 128, 128, 0, 0, 0]),
            ("rgb", [1, 2, 3, 4, 5, 6], 24, rgb, CGImageAlphaInfo.none.rawValue, [1, 2, 3, 4, 5, 6]),
            ("rgba straight", [1, 2, 3, 0, 4, 5, 6, 9], 32, rgb, CGImageAlphaInfo.last.rawValue | big,
             [1, 2, 3, 4, 5, 6]),
            ("rgbx little", [3, 2, 1, 0, 6, 5, 4, 0], 32, rgb, CGImageAlphaInfo.noneSkipFirst.rawValue | little,
             [1, 2, 3, 4, 5, 6]),
            ("bgra premultiplied little", [25, 50, 100, 128, 9, 9, 9, 0], 32, rgb,
             CGImageAlphaInfo.premultipliedFirst.rawValue | little, [199, 100, 50, 0, 0, 0]),
            ("argb premultiplied", [255, 10, 20, 30, 255, 40, 50, 60], 32, rgb,
             CGImageAlphaInfo.premultipliedFirst.rawValue | big, [10, 20, 30, 40, 50, 60]),
        ]
        for item in cases {
            let image = try #require(Self.image(width: 2, bytes: item.bytes, bitsPerComponent: 8,
                bitsPerPixel: item.bitsPerPixel, space: item.space, info: item.info), "\(item.name)")
            #expect(NemotronSuperImageIORaster.directLayout(image) != nil, "\(item.name)")
            #expect(try Self.write(image) == item.expected, "\(item.name)")
        }
        // An 8-bit palette expands through its RGB table.
        let indexed = try #require(CGColorSpace(indexedBaseSpace: rgb, last: 1, colorTable: [9, 8, 7, 1, 2, 3]))
        let paletted = try #require(Self.image(width: 2, bytes: [1, 0], bitsPerComponent: 8, bitsPerPixel: 8,
            space: indexed, info: CGImageAlphaInfo.none.rawValue))
        #expect(try Self.write(paletted) == [1, 2, 3, 9, 8, 7])
        // 16-bit RGB has no direct layout: it is drawn once, without colour conversion.
        let wide = try #require(Self.image(width: 1, bytes: [0x12, 0x12, 0x80, 0x80, 0xff, 0xff], bitsPerComponent: 16,
            bitsPerPixel: 48, space: rgb, info: CGImageAlphaInfo.none.rawValue))
        #expect(NemotronSuperImageIORaster.directLayout(wide) == nil)
        #expect(try Self.write(wide) == [0x12, 0x80, 0xff])
        // A layout neither read nor drawn (16-bit gray) is refused.
        let grayWide = try #require(Self.image(width: 1, bytes: [0x80, 0x00], bitsPerComponent: 16, bitsPerPixel: 16,
            space: gray, info: CGImageAlphaInfo.none.rawValue))
        #expect(throws: Decode.Failure.unsupportedEncoding) { try Self.write(grayWide) }
        #expect(NemotronSuperImageIORaster.unpremultiply(200, 0) == 0)
        #expect(NemotronSuperImageIORaster.unpremultiply(255, 1) == 255)
    }

    @Test func aSizeOtherThanTheWritersIsRefused() throws {
        let image = try #require(Self.image(width: 1, bytes: [1, 2, 3], bitsPerComponent: 8, bitsPerPixel: 24,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, info: CGImageAlphaInfo.none.rawValue))
        var writer = NemotronSuperOrientedRGBWriter(sourceWidth: 2, sourceHeight: 1, orientation: 1)
        #expect(throws: Decode.Failure.invalidRaster) { try NemotronSuperImageIORaster.write(image, into: &writer) }
    }

    // MARK: - Encoders and images

    private static func write(_ image: CGImage) throws -> [UInt8] {
        var writer = NemotronSuperOrientedRGBWriter(sourceWidth: image.width, sourceHeight: image.height,
                                                    orientation: 1)
        try NemotronSuperImageIORaster.write(image, into: &writer)
        return writer.rgb
    }

    /// One row of `width` pixels from raw `bytes`, rows packed.
    private static func image(width: Int, bytes: [UInt8], bitsPerComponent: Int, bitsPerPixel: Int,
                              space: CGColorSpace, info: UInt32) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: 1, bitsPerComponent: bitsPerComponent, bitsPerPixel: bitsPerPixel,
            bytesPerRow: bytes.count, space: space, bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider,
            decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    private static func le32(_ value: Int) -> [UInt8] { (0 ..< 4).map { UInt8((value >> (8 * $0)) & 0xff) } }
    private static func le16(_ value: Int) -> [UInt8] { (0 ..< 2).map { UInt8((value >> (8 * $0)) & 0xff) } }

    /// A 24-bit bottom-up BMP (BITMAPINFOHEADER) of `raster`.
    static func bmp(_ raster: NemotronSuperImageDecode.Raster) -> Data {
        let row = (raster.width * 3 + 3) / 4 * 4
        var pixels: [UInt8] = []
        for y in (0 ..< raster.height).reversed() {
            var line = [UInt8](repeating: 0, count: row)
            for x in 0 ..< raster.width {
                let source = (y * raster.width + x) * 3
                line[3 * x] = raster.rgb[source + 2]
                line[3 * x + 1] = raster.rgb[source + 1]
                line[3 * x + 2] = raster.rgb[source]
            }
            pixels += line
        }
        let header = Array("BM".utf8) + le32(54 + pixels.count) + le32(0) + le32(54)
        let info = le32(40) + le32(raster.width) + le32(raster.height) + le16(1) + le16(24) + le32(0)
            + le32(pixels.count) + le32(2835) + le32(2835) + le32(0) + le32(0)
        return Data(header + info + pixels)
    }

    /// A GIF89a of `raster`, which has at most 256 colours: a global table and
    /// one frame of 8-bit LZW codes with a clear code every 128 pixels, so
    /// the codes stay 9 bits wide and need no dictionary.
    static func gif(_ raster: NemotronSuperImageDecode.Raster) throws -> Data {
        var table: [[UInt8]] = [], index: [[UInt8]: Int] = [:], indices: [Int] = []
        for pixel in 0 ..< raster.width * raster.height {
            let colour = Array(raster.rgb[3 * pixel ..< 3 * pixel + 3])
            if index[colour] == nil { index[colour] = table.count; table.append(colour) }
            indices.append(index[colour]!)
        }
        try #require(table.count <= 256)
        let colours = table.flatMap { $0 } + [UInt8](repeating: 0, count: (256 - table.count) * 3)
        var codes: [Int] = []
        for (offset, value) in indices.enumerated() {
            if offset % 128 == 0 { codes.append(256) }
            codes.append(value)
        }
        codes.append(257)
        var bits: [UInt8] = [], accumulator = 0, count = 0
        for code in codes {
            accumulator |= code << count
            count += 9
            while count >= 8 { bits.append(UInt8(accumulator & 0xff)); accumulator >>= 8; count -= 8 }
        }
        if count > 0 { bits.append(UInt8(accumulator & 0xff)) }
        var blocks: [UInt8] = []
        for start in stride(from: 0, to: bits.count, by: 255) {
            let block = bits[start ..< min(start + 255, bits.count)]
            blocks += [UInt8(block.count)] + block
        }
        let screen = le16(raster.width) + le16(raster.height) + [0xf7, 0, 0]
        let descriptor = [0x2c] + le16(0) + le16(0) + le16(raster.width) + le16(raster.height) + [0]
        return Data(Array("GIF89a".utf8) + screen + colours + descriptor + [8] + blocks + [0, 0x3b])
    }
}
