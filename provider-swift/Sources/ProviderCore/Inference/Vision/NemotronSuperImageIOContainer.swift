// Copyright © 2026 Eigen Labs.
import CoreGraphics
import Foundation
import ImageIO

/// A WebP, GIF or BMP header: the signature, ImageIO's type and frame 0's
/// size, and for WebP the `EXIF` and `XMP ` chunks that Pillow's WebP plugin
/// keeps for `exif_transpose`. No raster is decoded here.
struct NemotronSuperImageIOContainer {
    typealias Format = NemotronSuperImageDecode.Format
    typealias Failure = NemotronSuperImageDecode.Failure

    let format: Format
    let width: Int
    let height: Int
    let exif: Data?
    let xmp: Data?

    /// The ImageIO type each sniffed signature must also have; any other
    /// type (TIFF, HEIC and the rest) is refused.
    static let typeIdentifiers: [Format: String] = [
        .webp: "org.webmproject.webp", .gif: "com.compuserve.gif", .bmp: "com.microsoft.bmp",
    ]

    /// The format of a WebP, GIF or BMP signature, else nil.
    static func format(of bytes: UnsafeRawBufferPointer) -> Format? {
        if bytes.count >= 12, bytes.starts(with: Array("RIFF".utf8)),
           bytes[8 ..< 12].elementsEqual("WEBP".utf8) { return .webp }
        if bytes.starts(with: Array("GIF87a".utf8)) || bytes.starts(with: Array("GIF89a".utf8)) { return .gif }
        if bytes.starts(with: Array("BM".utf8)) { return .bmp }
        return nil
    }

    static func parse(_ data: Data, format: Format) throws -> Self {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let type = typeIdentifiers[format],
              let source = CGImageSourceCreateWithData(data as CFData, options),
              CGImageSourceGetType(source) as String? == type, CGImageSourceGetCount(source) >= 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0
        else { throw Failure.invalidHeader }
        let metadata: (exif: Data?, xmp: Data?) = try format == .webp ? webPMetadata(data) : (nil, nil)
        return Self(format: format, width: width, height: height, exif: metadata.exif, xmp: metadata.xmp)
    }

    /// The `EXIF` and `XMP ` chunk payloads Pillow reads through libwebp's
    /// demuxer (`ParseVP8XChunks`): only in the extended format, whose first
    /// chunk is `VP8X`, and each only when its `VP8X` flag is set (`EXIF_FLAG`
    /// 0x08, `XMP_FLAG` 0x04); the first of each is kept. A simple-format
    /// WebP carries none. A chunk that runs past the RIFF payload is refused.
    static func webPMetadata(_ data: Data) throws -> (exif: Data?, xmp: Data?) {
        guard data.count >= 12 else { throw Failure.invalidHeader }
        let base = data.startIndex
        func littleEndian32(_ offset: Int) -> Int {
            (0 ..< 4).reduce(0) { value, index in value | Int(data[base + offset + index]) << (8 * index) }
        }
        let end = min(data.count, 8 + littleEndian32(4))
        func tag(_ offset: Int) -> Data.SubSequence { data[base + offset ..< base + offset + 4] }
        // The extended header: `VP8X`, at least 10 payload bytes, flags first.
        guard end >= 12 + 8 + 10, tag(12).elementsEqual("VP8X".utf8), littleEndian32(16) >= 10 else {
            return (nil, nil)
        }
        let flags = data[base + 20]
        let wantsEXIF = flags & 0x08 != 0, wantsXMP = flags & 0x04 != 0
        var offset = 12
        var exif: Data?, xmp: Data?
        while offset <= end - 8 {
            let size = littleEndian32(offset + 4), payload = offset + 8
            guard size <= end - payload else { throw Failure.invalidHeader }
            let bytes = { data.subdata(in: base + payload ..< base + payload + size) }
            if wantsEXIF, exif == nil, tag(offset).elementsEqual("EXIF".utf8) { exif = bytes() }
            if wantsXMP, xmp == nil, tag(offset).elementsEqual("XMP ".utf8) { xmp = bytes() }
            offset = payload + size + (size & 1)
        }
        return (exif, xmp)
    }
}
