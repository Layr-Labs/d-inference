// Copyright © 2026 Eigen Labs.
import Foundation
import MLXVLM

/// Unregistered CPU ingress for PNG and JPEG with the reference loader's RGB8
/// semantics: transformers `load_image` (Pillow `exif_transpose`, then
/// `convert("RGB")`) followed by NVIDIA's processor, which resizes floating
/// samples. The format is sniffed from content, as Pillow does. PNG is decoded
/// here exactly; JPEG samples come from ImageIO and differ from libjpeg-turbo
/// within the measured bounds in the Nemotron Super image-format reference.
/// No colour management is applied, as Pillow applies none by default.
enum NemotronSuperImageDecode {
    enum Failure: Error, Equatable { case invalidHeader, unsupportedEncoding, sizeLimit, invalidRaster }
    enum Orientation: Equatable, Sendable { case preserveRaster, applyEXIF }
    enum Format: Equatable, Sendable { case png, jpeg }
    struct Raster {
        let width: Int
        let height: Int
        let rgb: [UInt8]
    }
    struct Quote {
        let format: Format
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
    /// An image past every check that can refuse it before its raster is
    /// decoded. Only `plan` creates one; `prepare` decodes from this parse.
    struct Plan {
        let grid: NemotronSuperImagePreprocessing.Grid
        var quote: Quote { parsed.quote }
        fileprivate let data: Data
        fileprivate let parsed: Parsed
    }

    fileprivate enum Container {
        case png(NemotronSuperPNGContainer)
        case jpeg(NemotronSuperJPEGContainer)
    }
    fileprivate struct Parsed {
        let container: Container
        let quote: Quote
    }

    /// Local safety ceilings, not model-intrinsic limits. No URL or file access.
    /// Reads container metadata only; no buffer proportional to the declared
    /// raster is allocated. Header inspection itself needs a bounded
    /// encoded-buffer admission before use in a serving route; this quote does
    /// not grant that admission.
    static func inspect(_ data: Data, orientation policy: Orientation,
                        maxPixels: Int = MediaIngest.maxImagePixels,
                        maxEncodedBytes: Int = MediaIngest.maxMediaDecodedBytes) throws -> Quote {
        try parse(data, orientation: policy, maxPixels: maxPixels, maxEncodedBytes: maxEncodedBytes).quote
    }

    static func decode(_ data: Data, orientation: Orientation,
                       maxPixels: Int = MediaIngest.maxImagePixels) throws -> Raster {
        try rasterize(data, parse(data, orientation: orientation, maxPixels: maxPixels))
    }

    /// `inspect`, then the image's resize grid and the SDK's resize workspace
    /// for the oriented size `normalizeRGB` receives: an image above that
    /// workspace is refused here, before any admission or decode.
    static func plan(_ data: Data, orientation: Orientation, imageCount: Int) throws -> Plan {
        let parsed = try parse(data, orientation: orientation)
        let grid = try NemotronSuperImagePreprocessing.grid(
            width: parsed.quote.width, height: parsed.quote.height, imageCount: imageCount)
        try NemotronSuperImagePreprocessing.validateWorkspace(
            width: parsed.quote.width, height: parsed.quote.height, targetWidth: grid.width, targetHeight: grid.height)
        return Plan(grid: grid, data: data, parsed: parsed)
    }

    /// Obtain existing provider media admission for the plan's quote first.
    /// This helper does not reserve memory or bypass the media gate.
    static func prepare(_ plan: Plan) throws -> Prepared {
        let raster = try rasterize(plan.data, plan.parsed)
        return Prepared(grid: plan.grid, normalizedCHW: try NemotronSuperImagePreprocessing.normalizeRGB(
            raster.rgb, width: raster.width, height: raster.height,
            targetWidth: plan.grid.width, targetHeight: plan.grid.height))
    }

    static func prepare(_ data: Data, orientation: Orientation, imageCount: Int = 1) throws -> Prepared {
        try prepare(plan(data, orientation: orientation, imageCount: imageCount))
    }

    private static func parse(_ data: Data, orientation policy: Orientation,
                              maxPixels: Int = MediaIngest.maxImagePixels,
                              maxEncodedBytes: Int = MediaIngest.maxMediaDecodedBytes)
        throws -> Parsed {
        guard maxPixels > 0, maxEncodedBytes > 0, !data.isEmpty,
              data.count <= min(maxEncodedBytes, 64 * 1024 * 1024) else { throw Failure.sizeLimit }
        try Task.checkCancellation()
        let container: Container = try data.withUnsafeBytes { bytes in
            if bytes.starts(with: [137, 80, 78, 71]) { return .png(try NemotronSuperPNGContainer.parse(bytes)) }
            if bytes.starts(with: [0xff, 0xd8]) { return .jpeg(try NemotronSuperJPEGContainer.parse(bytes)) }
            throw Failure.unsupportedEncoding
        }
        let format: Format, width: Int, height: Int, exif: Data?, xmp: Data?
        switch container {
        case .png(let png): (format, width, height, exif, xmp) = (.png, png.width, png.height, png.exif, png.xmp)
        case .jpeg(let jpeg): (format, width, height, exif, xmp) = (.jpeg, jpeg.width, jpeg.height, jpeg.exif, jpeg.xmp)
        }
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        guard width <= 131072, height <= 131072, !overflow,
              pixels <= min(maxPixels, 64 * 1024 * 1024) else { throw Failure.sizeLimit }
        let orientation = policy == .applyEXIF ? try NemotronSuperImageOrientation.resolve(exif: exif, xmp: xmp) : 1
        // A conservative charge, not exact usage. PNG needs the 3-byte RGB8
        // output and row scratch; 14 bytes per pixel keeps the margin quoted
        // for the earlier ImageIO PNG path. JPEG adds ImageIO's 4-byte raster
        // and up to 8 bytes of progressive coefficients per pixel.
        let bytesPerPixel = format == .png ? 14 : 16
        let decoderBytes = data.count * 2 + pixels * bytesPerPixel + height * 128 + 8 * 1024 * 1024
        let quote = Quote(format: format, sourceWidth: width, sourceHeight: height,
            width: orientation >= 5 ? height : width, height: orientation >= 5 ? width : height,
            orientation: orientation, decoderWorkspaceBytes: decoderBytes,
            normalizationWorkspaceBytes: decoderBytes + 256 * 1024 * 1024)
        return Parsed(container: container, quote: quote)
    }

    private static func rasterize(_ data: Data, _ parsed: Parsed) throws -> Raster {
        try Task.checkCancellation()
        let orientation = parsed.quote.orientation
        let writer: NemotronSuperOrientedRGBWriter
        switch parsed.container {
        case .png(let png):
            writer = try data.withUnsafeBytes { try NemotronSuperPNGRaster.decode($0, png, orientation: orientation) }
        case .jpeg(let jpeg):
            writer = try NemotronSuperJPEGRaster.decode(data, jpeg, orientation: orientation)
        }
        guard writer.width == parsed.quote.width, writer.height == parsed.quote.height else {
            throw Failure.invalidRaster
        }
        return Raster(width: writer.width, height: writer.height, rgb: writer.rgb)
    }
}
