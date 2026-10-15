// Copyright © 2026 Eigen Labs.
import Foundation
import CoreGraphics
import ImageIO
import MLXVLM

/// Unregistered CPU ingress for a deliberately narrow, lossless RGB8 PNG subset.
/// NVIDIA's pinned processor converts PIL images to RGB, then resizes floating
/// samples. Rendering through CIImage would introduce color management and alpha
/// premultiplication before that operation. Read decoded sample bytes instead.
/// JPEG, palette, gray, alpha and ICC conversion require independent qualification.
enum NemotronSuperImageDecode {
    enum Failure: Error, Equatable { case invalidHeader, unsupportedEncoding, sizeLimit, invalidRaster }
    enum Orientation: Equatable, Sendable { case preserveRaster, applyEXIF }
    struct Raster {
        let width: Int
        let height: Int
        let rgb: [UInt8]
    }
    struct Quote {
        let sourceWidth: Int
        let sourceHeight: Int
        let width: Int
        let height: Int
        let orientation: Int
        let decoderWorkspaceBytes: Int
        /// Includes the SDK's full 256 MiB numeric-workspace safety budget.
        /// This is a conservative charge quote, not admission or measured usage.
        let normalizationWorkspaceBytes: Int
    }
    struct Prepared {
        let grid: NemotronSuperImagePreprocessing.Grid
        let normalizedCHW: [Float]
    }

    private static let crcTable: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 { crc = crc & 1 == 0 ? crc >> 1 : (crc >> 1) ^ 0xedb88320 }
        return crc
    }

    /// Local safety ceilings, not model-intrinsic limits. No URL or file access.
    /// Header inspection itself needs a bounded encoded-buffer admission before
    /// use in a serving route; this quote does not grant that admission.
    static func inspect(_ data: Data, orientation policy: Orientation,
                        maxPixels: Int = MediaIngest.maxImagePixels,
                        maxEncodedBytes: Int = MediaIngest.maxMediaDecodedBytes) throws -> Quote {
        guard maxPixels > 0, maxEncodedBytes > 0, !data.isEmpty,
              data.count <= min(maxEncodedBytes, 64 * 1024 * 1024) else { throw Failure.sizeLimit }
        // Normalize indices for callers passing a Data slice; allocation is capped.
        let data = Data(data)
        let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
        guard data.count >= 33, data.prefix(8).elementsEqual(signature) else { throw Failure.unsupportedEncoding }
        func word(_ offset: Int) -> Int {
            (0..<4).reduce(0) { ($0 << 8) | Int(data[data.startIndex + offset + $1]) }
        }
        guard word(8) == 13, String(bytes: data[12..<16], encoding: .ascii) == "IHDR" else {
            throw Failure.invalidHeader
        }
        let width = word(16), height = word(20)
        // PNG color type 2 has exactly RGB; type 6/tRNS cannot preserve hidden
        // RGB reliably after Apple's premultiplied decode and is rejected.
        guard data[24] == 8, data[25] == 2, data[26] == 0, data[27] == 0,
              data[28] <= 1 else { throw Failure.unsupportedEncoding }
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        guard width > 0, height > 0, width <= 131072, height <= 131072,
              !overflow, pixels <= min(maxPixels, 64 * 1024 * 1024) else { throw Failure.sizeLimit }
        var offset = 8, chunks = 0
        var seenHeader = false, seenData = false, seenEnd = false
        var seenEXIF = false, seenSRGB = false
        while offset <= data.count - 12 {
            try Task.checkCancellation()
            chunks += 1
            guard chunks <= 65536 else { throw Failure.sizeLimit }
            let count = word(offset)
            guard count <= data.count - offset - 12 else { throw Failure.invalidHeader }
            let type = word(offset + 4)
            switch type {
            case 0x49484452: // IHDR
                guard !seenHeader, offset == 8, count == 13 else { throw Failure.invalidHeader }
                seenHeader = true
            case 0x49444154: // IDAT; metadata below is rejected after the first IDAT.
                guard seenHeader, !seenEnd else { throw Failure.invalidHeader }
                seenData = true
            case 0x49454e44: // IEND
                guard seenData, !seenEnd, count == 0 else { throw Failure.invalidHeader }
                seenEnd = true
            case 0x65584966: // eXIf
                guard seenHeader, !seenData, !seenEXIF, count <= 65536 else { throw Failure.invalidHeader }
                seenEXIF = true
            case 0x73524742: // sRGB
                guard seenHeader, !seenData, !seenSRGB, count == 1,
                      data[offset + 8] <= 3 else { throw Failure.invalidHeader }
                seenSRGB = true
            default: throw Failure.unsupportedEncoding
            }
            var crc: UInt32 = 0xffffffff
            for index in (offset + 4)..<(offset + 8 + count) {
                if index.isMultiple(of: 65536) { try Task.checkCancellation() }
                crc = Self.crcTable[Int((crc ^ UInt32(data[index])) & 255)] ^ (crc >> 8)
            }
            guard crc ^ 0xffffffff == UInt32(word(offset + 8 + count)) else {
                throw Failure.invalidHeader
            }
            offset += count + 12
            if seenEnd { break }
        }
        guard seenEnd, offset == data.count else { throw Failure.invalidHeader }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              properties[kCGImagePropertyPixelWidth] as? Int == width,
              properties[kCGImagePropertyPixelHeight] as? Int == height else { throw Failure.invalidHeader }
        let exif = properties[kCGImagePropertyOrientation] as? Int ?? 1
        guard (1...8).contains(exif) else { throw Failure.invalidHeader }
        let orientation = policy == .applyEXIF ? exif : 1
        // ImageIO raster + provider copy + RGB output + orientation copy, with
        // row-padding allowance. Compressed codec internals are not exact usage.
        let decoderBytes = data.count * 2 + pixels * 14 + height * 128 + 8 * 1024 * 1024
        return Quote(sourceWidth: width, sourceHeight: height,
            width: orientation >= 5 ? height : width, height: orientation >= 5 ? width : height,
            orientation: orientation, decoderWorkspaceBytes: decoderBytes,
            normalizationWorkspaceBytes: decoderBytes + 256 * 1024 * 1024)
    }

    static func decode(_ data: Data, orientation: Orientation,
                       maxPixels: Int = MediaIngest.maxImagePixels) throws -> Raster {
        let quote = try inspect(data, orientation: orientation, maxPixels: maxPixels)
        try Task.checkCancellation()
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              let image = CGImageSourceCreateImageAtIndex(source, 0, options),
              image.width == quote.sourceWidth, image.height == quote.sourceHeight,
              image.bitsPerComponent == 8, [24, 32].contains(image.bitsPerPixel),
              image.colorSpace?.model == .rgb else { throw Failure.invalidRaster }
        let stride = image.bitsPerPixel / 8
        let order = image.bitmapInfo.intersection(.byteOrderMask)
        let channels: [Int]
        switch (stride, image.alphaInfo) {
        case (3, .none): channels = [0, 1, 2]
        case (4, .noneSkipLast), (4, .premultipliedLast), (4, .last): channels = order == .byteOrder32Little ? [3, 2, 1] : [0, 1, 2]
        case (4, .noneSkipFirst), (4, .premultipliedFirst), (4, .first): channels = order == .byteOrder32Little ? [2, 1, 0] : [1, 2, 3]
        default: throw Failure.unsupportedEncoding
        }
        guard image.bytesPerRow >= image.width * stride,
              image.bytesPerRow <= image.width * 4 + 64,
              let bytes = image.dataProvider?.data,
              CFDataGetLength(bytes) >= image.bytesPerRow * image.height,
              let raw = CFDataGetBytePtr(bytes) else { throw Failure.invalidRaster }
        var rgb = [UInt8](repeating: 0, count: quote.width * quote.height * 3)
        for y in 0..<image.height {
            if y.isMultiple(of: 16) { try Task.checkCancellation() }
            for x in 0..<image.width {
                if stride == 4 && image.alphaInfo != .noneSkipFirst && image.alphaInfo != .noneSkipLast {
                    // Some ImageIO versions pad opaque RGB sources with alpha.
                    let alpha = (0..<4).first { !channels.contains($0) }!
                    guard raw[y * image.bytesPerRow + x * stride + alpha] == 255 else {
                        throw Failure.unsupportedEncoding
                    }
                }
                let destination: (Int, Int)
                switch quote.orientation {
                case 2: destination = (image.width - 1 - x, y)
                case 3: destination = (image.width - 1 - x, image.height - 1 - y)
                case 4: destination = (x, image.height - 1 - y)
                case 5: destination = (y, x)
                case 6: destination = (image.height - 1 - y, x)
                case 7: destination = (image.height - 1 - y, image.width - 1 - x)
                case 8: destination = (y, image.width - 1 - x)
                default: destination = (x, y)
                }
                let base = (destination.1 * quote.width + destination.0) * 3
                for channel in 0..<3 { rgb[base + channel] = raw[y * image.bytesPerRow + x * stride + channels[channel]] }
            }
        }
        return Raster(width: quote.width, height: quote.height, rgb: rgb)
    }

    /// Call inspect first and obtain existing provider media admission for its
    /// quote. This helper does not reserve memory or bypass the media gate.
    static func prepare(_ data: Data, orientation: Orientation, imageCount: Int = 1) throws -> Prepared {
        let quote = try inspect(data, orientation: orientation)
        let grid = try NemotronSuperImagePreprocessing.grid(width: quote.width, height: quote.height, imageCount: imageCount)
        let raster = try decode(data, orientation: orientation)
        return Prepared(grid: grid, normalizedCHW: try NemotronSuperImagePreprocessing.normalizeRGB(
            raster.rgb, width: raster.width, height: raster.height, targetWidth: grid.width, targetHeight: grid.height))
    }
}
