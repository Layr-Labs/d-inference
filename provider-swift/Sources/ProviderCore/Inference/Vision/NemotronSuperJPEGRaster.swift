// Copyright © 2026 Eigen Labs.
import CoreGraphics
import Foundation
import ImageIO

/// Decodes the admitted primary JPEG frame with ImageIO and reads its sample
/// bytes without drawing, so no colour management or alpha premultiplication
/// is applied (Pillow ignores embedded ICC profiles too). Pillow's RGB
/// conversion is reproduced from those samples: gray replicates, and CMYK is
/// read as Adobe-inverted (`CMYK;I`) before Pillow's `cmyk2rgb`.
/// The IDCT and chroma upsampling are ImageIO's, not libjpeg-turbo's, so
/// decoded samples differ from Pillow by a few levels; with 2x2 chroma
/// subsampling ImageIO also replicates chroma at 16-pixel MCU edges.
enum NemotronSuperJPEGRaster {
    static func decode(_ data: Data, _ jpeg: NemotronSuperJPEGContainer,
                       orientation: Int) throws -> NemotronSuperOrientedRGBWriter {
        typealias Failure = NemotronSuperImageDecode.Failure
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options),
              CGImageSourceGetType(source) as String? == "public.jpeg", CGImageSourceGetCount(source) >= 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              properties[kCGImagePropertyPixelWidth] as? Int == jpeg.width,
              properties[kCGImagePropertyPixelHeight] as? Int == jpeg.height
        else { throw Failure.invalidRaster }
        try Task.checkCancellation()
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, options),
              image.width == jpeg.width, image.height == jpeg.height, image.bitsPerComponent == 8
        else { throw Failure.invalidRaster }
        let layout = try channelLayout(image, jpeg.colorModel)
        let stride = image.bitsPerPixel / 8
        guard image.bytesPerRow >= image.width * stride, image.bytesPerRow <= image.width * stride + 64,
              let provider = image.dataProvider?.data,
              CFDataGetLength(provider) >= image.bytesPerRow * (image.height - 1) + image.width * stride,
              let raw = CFDataGetBytePtr(provider)
        else { throw Failure.invalidRaster }
        try Task.checkCancellation()
        var writer = NemotronSuperOrientedRGBWriter(
            sourceWidth: jpeg.width, sourceHeight: jpeg.height, orientation: orientation)
        var row = [UInt8](repeating: 0, count: jpeg.width * 3)
        try row.withUnsafeMutableBufferPointer { rgb in
            let out = rgb.baseAddress!
            for y in 0..<image.height {
                if y.isMultiple(of: 64) { try Task.checkCancellation() }
                let line = raw + y * image.bytesPerRow
                for x in 0..<image.width {
                    let pixel = line + x * stride
                    switch jpeg.colorModel {
                    case .gray:
                        out[3 * x] = pixel[0]
                        out[3 * x + 1] = pixel[0]
                        out[3 * x + 2] = pixel[0]
                    case .yCbCr, .rgb:
                        for c in 0..<3 { out[3 * x + c] = pixel[layout[c]] }
                    case .cmyk:
                        // Inverted stored K is 255 - k, so Pillow's nk = K.
                        let k = Int(pixel[layout[3]])
                        for c in 0..<3 {
                            out[3 * x + c] = UInt8(clamping: k - mulDiv255(255 - Int(pixel[layout[c]]), k))
                        }
                    }
                }
                try writer.store(out, count: image.width, row: y)
            }
        }
        return writer
    }

    /// Pillow `MULDIV255`.
    private static func mulDiv255(_ a: Int, _ b: Int) -> Int {
        let product = a * b + 128
        return ((product >> 8) + product) >> 8
    }

    /// Sample offsets of R, G, B (or C, M, Y, K) within one pixel.
    private static func channelLayout(_ image: CGImage,
                                      _ model: NemotronSuperJPEGContainer.ColorModel) throws -> [Int] {
        let little = image.bitmapInfo.intersection(.byteOrderMask) == .byteOrder32Little
        switch (model, image.colorSpace?.model, image.bitsPerPixel, image.alphaInfo) {
        case (.gray, .monochrome?, 8, .none):
            return [0]
        case (.yCbCr, .rgb?, 24, .none), (.rgb, .rgb?, 24, .none):
            return [0, 1, 2]
        case (.yCbCr, .rgb?, 32, .noneSkipLast), (.rgb, .rgb?, 32, .noneSkipLast):
            return little ? [3, 2, 1] : [0, 1, 2]
        case (.yCbCr, .rgb?, 32, .noneSkipFirst), (.rgb, .rgb?, 32, .noneSkipFirst):
            return little ? [2, 1, 0] : [1, 2, 3]
        case (.cmyk, .cmyk?, 32, .none):
            return little ? [3, 2, 1, 0] : [0, 1, 2, 3]
        default:
            throw NemotronSuperImageDecode.Failure.invalidRaster
        }
    }
}
