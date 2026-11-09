// Copyright © 2026 Eigen Labs.
import CoreGraphics
import Foundation
import ImageIO

/// Decodes frame 0 of a WebP, GIF or BMP with ImageIO to Pillow's
/// `convert("RGB")` samples: alpha is dropped, gray replicates and a palette
/// expands. Samples are read without drawing, so no colour management
/// applies (Pillow ignores embedded profiles). Premultiplied samples are
/// divided by their alpha first, so a pixel with alpha 0 reads as black. An
/// RGB layout not read directly is drawn once into an 8-bit context in the
/// image's own colour space, which converts no colour.
enum NemotronSuperImageIORaster {
    typealias Failure = NemotronSuperImageDecode.Failure

    /// Offsets of one pixel's samples. `alpha` is set only for premultiplied
    /// samples, which are divided by it; a palette maps a one-byte index.
    struct Layout: Equatable {
        var stride: Int
        var red: Int, green: Int, blue: Int
        var premultipliedAlpha: Int?
        var palette: [UInt8]?

        static func rgb(stride: Int, _ red: Int, _ green: Int, _ blue: Int, alpha: Int? = nil) -> Layout {
            Layout(stride: stride, red: red, green: green, blue: blue, premultipliedAlpha: alpha, palette: nil)
        }
    }

    static func decode(_ data: Data, _ container: NemotronSuperImageIOContainer,
                       orientation: Int) throws -> NemotronSuperOrientedRGBWriter {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let type = NemotronSuperImageIOContainer.typeIdentifiers[container.format],
              let source = CGImageSourceCreateWithData(data as CFData, options),
              CGImageSourceGetType(source) as String? == type
        else { throw Failure.invalidRaster }
        try Task.checkCancellation()
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, options),
              image.width == container.width, image.height == container.height
        else { throw Failure.invalidRaster }
        var writer = NemotronSuperOrientedRGBWriter(
            sourceWidth: container.width, sourceHeight: container.height, orientation: orientation)
        try write(image, into: &writer)
        return writer
    }

    /// Stores `image`'s RGB samples in `writer`, whose source size it must
    /// have: read directly for a `directLayout`, else drawn once when its
    /// colour model is RGB; any other layout is `unsupportedEncoding`.
    static func write(_ image: CGImage, into writer: inout NemotronSuperOrientedRGBWriter) throws {
        guard image.width == writer.sourceWidth, image.height == writer.sourceHeight else {
            throw Failure.invalidRaster
        }
        if let layout = directLayout(image), image.bytesPerRow >= image.width * layout.stride,
           let samples = image.dataProvider?.data,
           CFDataGetLength(samples) >= image.bytesPerRow * (image.height - 1) + image.width * layout.stride,
           let raw = CFDataGetBytePtr(samples) {
            try withExtendedLifetime(samples) {
                try convert(raw, bytesPerRow: image.bytesPerRow, layout: layout, into: &writer)
            }
            return
        }
        // Any other RGB layout (another depth or byte order): one drawn copy.
        guard let space = image.colorSpace, space.model == .rgb,
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                  bytesPerRow: image.width * 4, space: space,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        else { throw Failure.unsupportedEncoding }
        context.interpolationQuality = .none
        context.setBlendMode(.copy)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let drawn = context.data else { throw Failure.invalidRaster }
        try withExtendedLifetime(context) {
            try convert(drawn.assumingMemoryBound(to: UInt8.self), bytesPerRow: context.bytesPerRow,
                        layout: .rgb(stride: 4, 0, 1, 2, alpha: 3), into: &writer)
        }
    }

    /// The layouts read without drawing: 8-bit gray, gray with alpha, RGB
    /// with or without alpha in either 32-bit byte order, and an 8-bit
    /// palette over RGB. nil for every other layout.
    static func directLayout(_ image: CGImage) -> Layout? {
        guard image.bitsPerComponent == 8, let space = image.colorSpace else { return nil }
        let order = image.bitmapInfo.intersection(.byteOrderMask)
        let little = order == .byteOrder32Little
        guard order == [] || order == .byteOrder32Big || (little && image.bitsPerPixel == 32) else { return nil }
        let alpha = image.alphaInfo
        let premultiplied = alpha == .premultipliedLast || alpha == .premultipliedFirst
        let alphaLast: Bool = alpha == .last || alpha == .premultipliedLast || alpha == .noneSkipLast
        let alphaFirst: Bool = alpha == .first || alpha == .premultipliedFirst || alpha == .noneSkipFirst
        switch (space.model, image.bitsPerPixel) {
        case (.monochrome, 8) where alpha == .none:
            return .rgb(stride: 1, 0, 0, 0)
        case (.monochrome, 16) where order == [] && (alphaLast || alphaFirst):
            let gray = alphaLast ? 0 : 1
            return .rgb(stride: 2, gray, gray, gray, alpha: premultiplied ? 1 - gray : nil)
        case (.rgb, 24) where alpha == .none:
            return .rgb(stride: 3, 0, 1, 2)
        case (.rgb, 32) where alphaLast || alphaFirst:
            // Memory order: RGBA, ARGB, or reversed in a little-endian word.
            let (r, g, b, a) = switch (alphaLast, little) {
            case (true, false): (0, 1, 2, 3)
            case (false, false): (1, 2, 3, 0)
            case (true, true): (3, 2, 1, 0)
            case (false, true): (2, 1, 0, 3)
            }
            return .rgb(stride: 4, r, g, b, alpha: premultiplied ? a : nil)
        case (.indexed, 8) where alpha == .none:
            guard space.baseColorSpace?.model == .rgb, space.baseColorSpace?.numberOfComponents == 3,
                  let table = space.colorTable, !table.isEmpty, table.count % 3 == 0
            else { return nil }
            return Layout(stride: 1, red: 0, green: 0, blue: 0, premultipliedAlpha: nil, palette: table)
        default:
            return nil
        }
    }

    static func convert(_ raw: UnsafePointer<UInt8>, bytesPerRow: Int, layout: Layout,
                        into writer: inout NemotronSuperOrientedRGBWriter) throws {
        let width = writer.sourceWidth
        var row = [UInt8](repeating: 0, count: width * 3)
        try row.withUnsafeMutableBufferPointer { rgb in
            let out = rgb.baseAddress!
            for y in 0 ..< writer.sourceHeight {
                if y.isMultiple(of: 64) { try Task.checkCancellation() }
                let line = raw + y * bytesPerRow
                for x in 0 ..< width {
                    let pixel = line + x * layout.stride
                    if let palette = layout.palette {
                        let entry = Int(pixel[0]) * 3
                        guard entry + 2 < palette.count else { throw Failure.invalidRaster }
                        for c in 0 ..< 3 { out[3 * x + c] = palette[entry + c] }
                        continue
                    }
                    let red = pixel[layout.red], green = pixel[layout.green], blue = pixel[layout.blue]
                    if let offset = layout.premultipliedAlpha {
                        let alpha = pixel[offset]
                        out[3 * x] = unpremultiply(red, alpha)
                        out[3 * x + 1] = unpremultiply(green, alpha)
                        out[3 * x + 2] = unpremultiply(blue, alpha)
                    } else {
                        out[3 * x] = red
                        out[3 * x + 1] = green
                        out[3 * x + 2] = blue
                    }
                }
                try writer.store(out, count: width, row: y)
            }
        }
    }

    /// A premultiplied sample over its alpha, rounded; alpha 0 gives 0.
    static func unpremultiply(_ sample: UInt8, _ alpha: UInt8) -> UInt8 {
        guard alpha > 0 else { return 0 }
        return UInt8(min(255, (Int(sample) * 255 + Int(alpha) / 2) / Int(alpha)))
    }
}
