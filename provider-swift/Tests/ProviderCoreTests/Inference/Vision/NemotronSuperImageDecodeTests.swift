import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import zlib
@testable import ProviderCore

struct NemotronSuperImageDecodeTests {
    private let rgbPNG = "iVBORw0KGgoAAAANSUhEUgAAAAIAAAADCAIAAAA2iEnWAAAAF0lEQVR4nGP4z8DAAMIM////B7GA8D8ATsYI+GrYM84AAAAASUVORK5CYII="
    private let rotatedPNG = "iVBORw0KGgoAAAANSUhEUgAAAAIAAAADCAIAAAA2iEnWAAAAGmVYSWZJSSoACAAAAAEAEgEDAAEAAAAGAAAAAAAAALdIESkAAAAXSURBVHicY/jPwMAAwgz///8HsYDwPwBOxgj4atgzzgAAAABJRU5ErkJggg=="
    private let alphaPNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGM4kWLEAAAEtQFfoI2A0AAAAABJRU5ErkJggg=="
    private let redPNG = "iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAIAAACQkWg2AAAAF0lEQVR4nGP4z8BAEiJN9aiGUQ1DSgMAkPn/Afnh+ngAAAAASUVORK5CYII="
    private let colors: [UInt8] = [255,0,0, 0,255,0, 0,0,255, 255,255,0, 255,0,255, 0,255,255]

    @Test func losslessRGBSamplesAndExplicitEXIFPolicy() throws {
        let bytes = try #require(Data(base64Encoded: rgbPNG))
        let raster = try NemotronSuperImageDecode.decode(bytes, orientation: .preserveRaster)
        #expect(raster.width == 2 && raster.height == 3)
        #expect(raster.rgb == colors)
        let rotated = try #require(Data(base64Encoded: rotatedPNG))
        let unchanged = try NemotronSuperImageDecode.decode(rotated, orientation: .preserveRaster)
        #expect(unchanged.rgb == colors)
        let oriented = try NemotronSuperImageDecode.decode(rotated, orientation: .applyEXIF)
        #expect(oriented.width == 3 && oriented.height == 2)
        #expect(oriented.rgb == [255,0,255, 0,0,255, 255,0,0, 0,255,255, 255,255,0, 0,255,0])
    }

    @Test func dropsAlphaAndRejectsOversizeBeforeRasterDecode() throws {
        // Fully transparent RGBA(200, 100, 50, 0): Pillow keeps the stored RGB.
        let alpha = try #require(Data(base64Encoded: alphaPNG))
        #expect(try NemotronSuperImageDecode.decode(alpha, orientation: .preserveRaster).rgb == [200, 100, 50])
        let rgb = try #require(Data(base64Encoded: rgbPNG))
        #expect(throws: NemotronSuperImageDecode.Failure.sizeLimit) {
            try NemotronSuperImageDecode.inspect(rgb, orientation: .preserveRaster, maxPixels: 5)
        }
        #expect(throws: NemotronSuperImageDecode.Failure.sizeLimit) {
            try NemotronSuperImageDecode.inspect(rgb, orientation: .preserveRaster, maxEncodedBytes: 1)
        }
        // A JPEG signature followed directly by EOI has no frame.
        #expect(throws: NemotronSuperImageDecode.Failure.invalidHeader) {
            try NemotronSuperImageDecode.inspect(Data([0xff, 0xd8, 0xff, 0xd9]), orientation: .preserveRaster)
        }
    }

    @Test func rejectsMissingTerminatorDuplicateHeaderAndCorruptCRC() throws {
        let png = try #require(Data(base64Encoded: rgbPNG))
        let missingEnd = Data(png.dropLast(12))
        let headerOnly = Data(png.prefix(33))
        var duplicate = Data(png.prefix(33))
        duplicate.append(png[8..<33])
        duplicate.append(png.dropFirst(33))
        var corrupt = png
        corrupt[29] ^= 1
        for bytes in [missingEnd, headerOnly, duplicate, corrupt] {
            #expect(throws: NemotronSuperImageDecode.Failure.invalidHeader) {
                try NemotronSuperImageDecode.inspect(bytes, orientation: .preserveRaster)
            }
        }
    }

    @Test func constantRGBNormalizationUsesSDKFloatPathAndQuotesWorkspace() throws {
        let data = try #require(Data(base64Encoded: redPNG))
        let quote = try NemotronSuperImageDecode.inspect(data, orientation: .applyEXIF)
        #expect(quote.normalizationWorkspaceBytes == quote.decoderWorkspaceBytes + 256 * 1024 * 1024)
        let result = try NemotronSuperImageDecode.prepare(data, orientation: .applyEXIF)
        let plane = result.grid.width * result.grid.height
        let expected: [Float] = [(1 - 0.48145466) / 0.26862954, -0.4578275 / 0.26130258, -0.40821073 / 0.27577711]
        #expect(result.normalizedCHW.count == plane * 3)
        for c in 0..<3 {
            #expect(result.normalizedCHW[(c * plane)..<((c + 1) * plane)].allSatisfy { abs($0 - expected[c]) < 0.00001 })
        }
    }
}

// MARK: - Limits, sniffing and fail-closed refusal

extension NemotronSuperImageDecodeTests {
    @Test func declaredGeometryIsBoundedBeforeAnyRasterAllocation() throws {
        // Valid chunk structure with a raster that is never inflated.
        for (width, height) in [(100_000, 100_000), (131_073, 1), (1, 131_073)] {
            let bytes = SuperImageTestPNG.image(width: width, height: height, colorType: 0, depth: 1, rows: [[0, 0]])
            #expect(throws: NemotronSuperImageDecode.Failure.sizeLimit) {
                try NemotronSuperImageDecode.decode(bytes, orientation: .applyEXIF)
            }
        }
        // libjpeg-turbo refuses dimensions above 65500.
        var jpeg = try NemotronSuperImageFixtures.data("jpeg-gray.jpeg")
        let frame = try #require(SuperImageTestJPEG.segment(0xc0, in: jpeg))
        jpeg.replaceSubrange((frame + 5)..<(frame + 9), with: [0xff, 0xff, 0x00, 0x01])
        #expect(throws: NemotronSuperImageDecode.Failure.sizeLimit) {
            try NemotronSuperImageDecode.inspect(jpeg, orientation: .applyEXIF)
        }
        #expect(throws: NemotronSuperImageDecode.Failure.sizeLimit) {
            try NemotronSuperImageDecode.inspect(Data(), orientation: .applyEXIF)
        }
    }

    @Test func formatIsSniffedAndOtherContainersAreRefused() throws {
        let signatures: [[UInt8]] = [
            Array("GIF89a".utf8) + [1, 0, 1, 0, 0, 0, 0],
            Array("RIFF".utf8) + [4, 0, 0, 0] + Array("WEBPVP8 ".utf8),
            Array("BM".utf8) + [UInt8](repeating: 0, count: 30),
            [0x49, 0x49, 0x2a, 0x00, 8, 0, 0, 0],
            [0, 0, 0, 0x18] + Array("ftypheic".utf8),
            [137, 80, 78, 71, 13, 10, 26, 0],
        ]
        for signature in signatures {
            #expect(throws: NemotronSuperImageDecode.Failure.unsupportedEncoding) {
                try NemotronSuperImageDecode.inspect(Data(signature), orientation: .applyEXIF)
            }
        }
        // The data-URI media type is not trusted: content decides, as in Pillow.
        let jpeg = try NemotronSuperImageFixtures.data("jpeg-444.jpeg")
        #expect(try NemotronSuperImageDecode.inspect(jpeg, orientation: .applyEXIF).format == .jpeg)
    }

    @Test func malformedOrUnqualifiedPNGFailsClosed() throws {
        typealias Failure = NemotronSuperImageDecode.Failure
        let gray = SuperImageTestPNG.image(width: 2, height: 1, colorType: 0, depth: 8, rows: [[0, 7, 9]])
        let palette = SuperImageTestPNG.chunk("PLTE", [1, 2, 3, 4, 5, 6])
        let exif = SuperImageTestPNG.chunk("eXIf", SuperImageTestPNG.tiff(orientation: 6))
        let cases: [(String, Data, Failure)] = [
            ("unknown critical chunk", SuperImageTestPNG.image(width: 2, height: 1, colorType: 0, depth: 8,
                rows: [[0, 7, 9]], before: [SuperImageTestPNG.chunk("CgBI", [0, 0, 0, 0])]), .unsupportedEncoding),
            ("PLTE in grayscale", SuperImageTestPNG.image(width: 2, height: 1, colorType: 0, depth: 8,
                rows: [[0, 7, 9]], before: [palette]), .invalidHeader),
            ("palette index beyond PLTE", SuperImageTestPNG.image(width: 2, height: 1, colorType: 3, depth: 8,
                rows: [[0, 1, 2]], before: [palette]), .invalidRaster),
            ("palette depth 16", SuperImageTestPNG.image(width: 1, height: 1, colorType: 3, depth: 16,
                rows: [[0, 0, 0]], before: [palette]), .invalidHeader),
            ("filter type 5", SuperImageTestPNG.image(width: 2, height: 1, colorType: 0, depth: 8,
                rows: [[5, 7, 9]]), .invalidRaster),
            ("more pixel data than the raster", SuperImageTestPNG.image(width: 2, height: 1, colorType: 0, depth: 8,
                rows: [[0, 7, 9], [0, 1, 1]]), .invalidRaster),
            ("fewer rows than the raster", SuperImageTestPNG.image(width: 2, height: 2, colorType: 0, depth: 8,
                rows: [[0, 7, 9]]), .invalidRaster),
            ("truncated zlib stream", SuperImageTestPNG.image(width: 2, height: 1, colorType: 0, depth: 8,
                stream: Array(SuperImageTestPNG.deflate([0, 7, 9]).dropLast(4))), .invalidRaster),
            ("data after IEND", gray + Data([0]), .invalidHeader),
            ("IDAT split by another chunk", SuperImageTestPNG.image(width: 2, height: 1, colorType: 0, depth: 8,
                rows: [[0, 7, 9]], splitIDATWith: SuperImageTestPNG.chunk("tEXt", Array("a\u{0}b".utf8))), .invalidHeader),
            ("interlace method 2", SuperImageTestPNG.image(width: 2, height: 1, colorType: 0, depth: 8,
                rows: [[0, 7, 9]], interlace: 2), .invalidHeader),
            ("raw-profile EXIF without eXIf", SuperImageTestPNG.image(width: 2, height: 1, colorType: 0, depth: 8,
                rows: [[0, 7, 9]], before: [SuperImageTestPNG.chunk("tEXt", Array("Raw profile type exif\u{0}x".utf8))]),
                .unsupportedEncoding),
            ("tEXt stored as Pillow's exif key", SuperImageTestPNG.image(width: 2, height: 1, colorType: 0, depth: 8,
                rows: [[0, 7, 9]], before: [SuperImageTestPNG.chunk("tEXt", Array("exif\u{0}x".utf8))]), .unsupportedEncoding),
            ("non-TIFF eXIf", SuperImageTestPNG.image(width: 2, height: 1, colorType: 0, depth: 8, rows: [[0, 7, 9]],
                before: [SuperImageTestPNG.chunk("eXIf", Array("XX*\u{0}\u{8}\u{0}\u{0}\u{0}".utf8))]), .unsupportedEncoding),
            ("BigTIFF eXIf", SuperImageTestPNG.image(width: 2, height: 1, colorType: 0, depth: 8, rows: [[0, 7, 9]],
                before: [SuperImageTestPNG.chunk("eXIf", [0x49, 0x49, 0x2b, 0, 8, 0, 0, 0])]), .unsupportedEncoding),
            ("short eXIf", SuperImageTestPNG.image(width: 2, height: 1, colorType: 0, depth: 8, rows: [[0, 7, 9]],
                before: [SuperImageTestPNG.chunk("eXIf", [0x49, 0x49, 0x2a, 0, 8])]), .invalidHeader),
            ("RATIONAL Orientation", SuperImageTestPNG.image(width: 2, height: 1, colorType: 0, depth: 8, rows: [[0, 7, 9]],
                before: [SuperImageTestPNG.chunk("eXIf", SuperImageTestPNG.tiff(orientation: 6, type: 5))]), .unsupportedEncoding),
            ("two XMP packets", SuperImageTestPNG.image(width: 2, height: 1, colorType: 0, depth: 8, rows: [[0, 7, 9]],
                before: [SuperImageTestPNG.xmp("6"), SuperImageTestPNG.xmp("3")]), .unsupportedEncoding),
            ("zTXt with a non-zlib method", SuperImageTestPNG.image(width: 2, height: 1, colorType: 0, depth: 8,
                rows: [[0, 7, 9]], before: [SuperImageTestPNG.chunk("zTXt", Array("Title\u{0}\u{1}x".utf8))]), .invalidHeader),
            ("XMP above Pillow's text limit", SuperImageTestPNG.image(width: 2, height: 1, colorType: 0, depth: 8,
                rows: [[0, 7, 9]], before: [SuperImageTestPNG.chunk("zTXt", Array("XML:com.adobe.xmp\u{0}\u{0}".utf8)
                    + SuperImageTestPNG.deflate([UInt8](repeating: 32, count: 1024 * 1024 + 1)))]), .sizeLimit),
            ("fcTL without acTL", SuperImageTestPNG.image(width: 2, height: 1, colorType: 0, depth: 8, rows: [[0, 7, 9]],
                before: [SuperImageTestPNG.frameControl(sequence: 0, width: 2, height: 1)]), .invalidHeader),
            ("APNG first frame smaller than the canvas", SuperImageTestPNG.image(width: 2, height: 1, colorType: 0,
                depth: 8, rows: [[0, 7, 9]], before: [SuperImageTestPNG.animationControl,
                    SuperImageTestPNG.frameControl(sequence: 0, width: 1, height: 1)]), .unsupportedEncoding),
            ("eXIf after a later APNG frame", SuperImageTestPNG.image(width: 2, height: 1, colorType: 0, depth: 8,
                rows: [[0, 7, 9]], before: [SuperImageTestPNG.animationControl],
                after: [SuperImageTestPNG.frameControl(sequence: 0, width: 2, height: 1), exif]), .unsupportedEncoding),
        ]
        for (name, bytes, failure) in cases {
            #expect(throws: failure, "\(name)") { try NemotronSuperImageDecode.decode(bytes, orientation: .applyEXIF) }
        }
        // The same EXIF before the APNG frame boundary is honoured.
        let rotated = SuperImageTestPNG.image(width: 2, height: 1, colorType: 0, depth: 8, rows: [[0, 7, 9]],
            before: [SuperImageTestPNG.animationControl], after: [exif, SuperImageTestPNG.frameControl(sequence: 0, width: 2, height: 1)])
        let raster = try NemotronSuperImageDecode.decode(rotated, orientation: .applyEXIF)
        #expect(raster.width == 1 && raster.height == 2 && raster.rgb == [7, 7, 7, 9, 9, 9])
    }

    @Test func unqualifiedJPEGVariantsFailClosed() throws {
        typealias Failure = NemotronSuperImageDecode.Failure
        let base = try NemotronSuperImageFixtures.data("jpeg-420.jpeg")
        let frame = try #require(SuperImageTestJPEG.segment(0xc0, in: base))
        func edited(_ data: Data, _ edit: (inout Data) -> Void) -> Data {
            var copy = data
            edit(&copy)
            return copy
        }
        let adobe0 = Data([0xff, 0xee, 0, 14] + Array("Adobe".utf8) + [0, 100, 0, 0, 0, 0, 0])
        let cmyk = try NemotronSuperImageFixtures.data("jpeg-cmyk.jpeg")
        let cmykAdobe = try #require(SuperImageTestJPEG.segment(0xee, in: cmyk))
        let rgb = try NemotronSuperImageFixtures.data("jpeg-rgb.jpeg")
        let cases: [(String, Data, Failure)] = [
            ("12-bit precision", edited(base) { $0[frame + 4] = 12 }, .unsupportedEncoding),
            ("arithmetic coding", edited(base) { $0[frame + 1] = 0xc9 }, .unsupportedEncoding),
            ("lossless process", edited(base) { $0[frame + 1] = 0xc3 }, .unsupportedEncoding),
            ("height defined by DNL", edited(base) { $0[frame + 5] = 0; $0[frame + 6] = 0 }, .unsupportedEncoding),
            ("4:1:1 luma sampling", edited(base) { $0[frame + 11] = 0x41 }, .unsupportedEncoding),
            ("YCCK transform", edited(cmyk) { $0[cmykAdobe + 15] = 2 }, .unsupportedEncoding),
            ("JFIF with Adobe RGB transform", base.prefix(2) + adobe0 + base.dropFirst(2), .unsupportedEncoding),
            ("RGB component IDs without Adobe", SuperImageTestJPEG.removing(0xee, from: rgb), .unsupportedEncoding),
            ("reserved marker", base.prefix(2) + Data([0xff, 0x02, 0, 2]) + base.dropFirst(2), .invalidHeader),
            ("missing EOI", Data(base.dropLast(2)), .invalidHeader),
            ("no frame before scan", Data([0xff, 0xd8, 0xff, 0xda, 0, 8, 1, 1, 0, 0, 63, 0, 0, 0xff, 0xd9]),
             .invalidHeader),
        ]
        for (name, bytes, failure) in cases {
            #expect(throws: failure, "\(name)") { try NemotronSuperImageDecode.inspect(bytes, orientation: .applyEXIF) }
        }
    }

    /// Byte flips, truncations and CRC-repaired PNG corruptions must decode or
    /// throw a decoder Failure; nothing may trap or escape as another error.
    @Test func corruptedInputsDecodeOrFailClosed() throws {
        var generator = SuperImageSplitMix64(seed: 0x5eed_1a6e)
        for file in ["png-rgb8.png", "png-palette4-adam7.png", "png-xmp3-itxt-compressed.png",
                     "png-rgba16-adam7.png", "jpeg-420.jpeg", "jpeg-444-progressive.jpeg", "jpeg-exif6.jpeg"] {
            let original = try NemotronSuperImageFixtures.data(file)
            for trial in 0..<150 {
                var bytes = original
                if trial % 5 == 4 {
                    bytes = Data(bytes.prefix(Int(generator.next() % UInt64(bytes.count))))
                } else {
                    for _ in 0...(generator.next() % 4) {
                        let index = Int(generator.next() % UInt64(bytes.count))
                        bytes[index] ^= UInt8(truncatingIfNeeded: generator.next() | 1)
                    }
                    if file.hasSuffix(".png"), trial % 2 == 0 { bytes = SuperImageTestPNG.repairingCRCs(bytes) }
                }
                do {
                    _ = try NemotronSuperImageDecode.decode(bytes, orientation: .applyEXIF)
                } catch is NemotronSuperImageDecode.Failure {
                } catch {
                    Issue.record("\(file) trial \(trial) threw \(error)")
                }
            }
        }
    }

    @Test func cancellationStopsInspectionAndDecode() async throws {
        let data = try NemotronSuperImageFixtures.data("png-rgb8-2560x1440.png")
        let decode = Task { () throws -> NemotronSuperImageDecode.Raster in
            withUnsafeCurrentTask { $0?.cancel() }
            return try NemotronSuperImageDecode.decode(data, orientation: .applyEXIF)
        }
        await #expect(throws: CancellationError.self) { try await decode.value }
        let inspect = Task { () throws -> NemotronSuperImageDecode.Quote in
            withUnsafeCurrentTask { $0?.cancel() }
            return try NemotronSuperImageDecode.inspect(data, orientation: .applyEXIF)
        }
        await #expect(throws: CancellationError.self) { try await inspect.value }
    }

    /// Verdicts checked against Pillow 12.2.0 on the same constructions: a
    /// compressed chunk may inflate to exactly 1 MiB, text may total exactly
    /// 64 MiB, and corrupt, truncated or malformed non-XMP chunks are ignored.
    /// A second iCCP is refused as hardening; Pillow reads every copy.
    @Test func compressedChunkLimitsMatchPillow() throws {
        let mebibyte = 1024 * 1024
        func spaces(_ count: Int) -> [UInt8] { SuperImageTestPNG.deflate([UInt8](repeating: 32, count: count)) }
        func image(_ chunks: [Data]) -> Data {
            SuperImageTestPNG.image(width: 2, height: 1, colorType: 0, depth: 8, rows: [[0, 7, 9]], before: chunks)
        }
        let corrupt: [UInt8] = [0x78, 0x9c, 0xff, 0xff, 0xff]
        let keyed = { (keyword: String, body: [UInt8]) in Array(keyword.utf8) + [0, 0] + body }
        let accepted: [(String, [Data])] = [
            ("zTXt of exactly 1 MiB", [SuperImageTestPNG.chunk("zTXt", keyed("Title", spaces(mebibyte)))]),
            ("corrupt zTXt", [SuperImageTestPNG.chunk("zTXt", keyed("Title", corrupt))]),
            ("truncated zTXt", [SuperImageTestPNG.chunk("zTXt", keyed("Title", Array(spaces(1000).dropLast(6))))]),
            ("corrupt compressed iTXt", [SuperImageTestPNG.chunk("iTXt", Array("Desc".utf8) + [0, 1, 0]
                + Array("en".utf8) + [0, 0] + corrupt)]),
            ("malformed iTXt", [SuperImageTestPNG.chunk("iTXt", Array("Desc".utf8) + [0, 1])]),
            ("iTXt that is not UTF-8", [SuperImageTestPNG.chunk("iTXt", Array("Desc".utf8) + [0, 0, 0]
                + Array("en".utf8) + [0, 0, 0xff, 0xfe])]),
            ("iCCP of exactly 1 MiB", [SuperImageTestPNG.chunk("iCCP", keyed("icc", spaces(mebibyte)))]),
            ("corrupt iCCP", [SuperImageTestPNG.chunk("iCCP", keyed("icc", corrupt))]),
        ]
        for (name, chunks) in accepted {
            #expect(try NemotronSuperImageDecode.decode(image(chunks), orientation: .applyEXIF).rgb
                    == [7, 7, 7, 9, 9, 9], "\(name)")
        }
        typealias Failure = NemotronSuperImageDecode.Failure
        let refused: [(String, [Data], Failure)] = [
            ("zTXt over 1 MiB", [SuperImageTestPNG.chunk("zTXt", keyed("Title", spaces(mebibyte + 1)))], .sizeLimit),
            ("unkeyed zTXt over 1 MiB", [SuperImageTestPNG.chunk("zTXt", [0, 0] + spaces(mebibyte + 1))], .sizeLimit),
            ("compressed iTXt over 1 MiB", [SuperImageTestPNG.chunk("iTXt", Array("Desc".utf8) + [0, 1, 0]
                + Array("en".utf8) + [0, 0] + spaces(mebibyte + 1))], .sizeLimit),
            ("iCCP over 1 MiB", [SuperImageTestPNG.chunk("iCCP", keyed("icc", spaces(mebibyte + 1)))], .sizeLimit),
            ("second iCCP", [SuperImageTestPNG.chunk("iCCP", keyed("icc", spaces(10))),
                             SuperImageTestPNG.chunk("iCCP", keyed("icc", spaces(10)))], .invalidHeader),
        ]
        for (name, chunks, failure) in refused {
            #expect(throws: failure, "\(name)") {
                try NemotronSuperImageDecode.inspect(image(chunks), orientation: .applyEXIF)
            }
        }
        // Stored text may total exactly 64 MiB. An image inflates at most
        // 16 MiB (`NemotronSuperPNGTextTests`), so the rest is plain tEXt,
        // which needs the decoder's 64 MiB encoded ceiling.
        func plain(_ keyword: String, _ characters: Int) -> Data {
            SuperImageTestPNG.chunk("tEXt", Array(keyword.utf8) + [0] + [UInt8](repeating: 32, count: characters))
        }
        let stored = (0..<16).map { SuperImageTestPNG.chunk("zTXt", keyed("T\($0)", spaces(mebibyte))) }
            + [plain("x", 48 * mebibyte - 1)]
        func text(last characters: Int) throws -> NemotronSuperImageDecode.Quote {
            try NemotronSuperImageDecode.inspect(image(stored + [plain("y", characters)]), orientation: .applyEXIF,
                                                 maxEncodedBytes: 64 * mebibyte)
        }
        #expect(try text(last: 1).width == 2, "text totalling exactly 64 MiB")
        #expect(throws: Failure.sizeLimit, "text over 64 MiB") { try text(last: 2) }
    }

    @Test func progressiveScanCountIsCapped() throws {
        // Container-level check only: ImageIO never sees these headers. A
        // legal 896-scan progression: each coefficient alone, in a first scan
        // (Al = 13) and thirteen one-bit refinements.
        let frame: [UInt8] = [0xff, 0xc2, 0, 11, 8, 0, 8, 0, 8, 1, 1, 0x11, 0]
        let progression = (0...63).flatMap { band in
            (0...13).map { pass -> [UInt8] in
                let high = pass == 0 ? 0 : 14 - pass, low = pass == 0 ? 13 : high - 1
                return [0xff, 0xda, 0, 8, 1, 1, 0, UInt8(band), UInt8(band), UInt8(high << 4 | low)]
            }
        }
        func jpeg(scans: Int) -> Data {
            Data([0xff, 0xd8] + frame + Array(progression.prefix(scans).joined()) + [0xff, 0xd9])
        }
        let limit = NemotronSuperJPEGContainer.maximumScans
        #expect(limit == 500 && progression.count > limit)
        #expect(try NemotronSuperImageDecode.inspect(jpeg(scans: limit), orientation: .applyEXIF).format == .jpeg)
        #expect(throws: NemotronSuperImageDecode.Failure.unsupportedEncoding) {
            try NemotronSuperImageDecode.inspect(jpeg(scans: limit + 1), orientation: .applyEXIF)
        }
    }
}

// MARK: - Fixture builders

/// Minimal PNG writer for structural cases; rows include their filter byte.
enum SuperImageTestPNG {
    static func chunk(_ type: String, _ body: [UInt8]) -> Data {
        let kind = Array(type.utf8)
        let crc = (kind + body).withUnsafeBufferPointer { UInt32(crc32(0, $0.baseAddress, UInt32($0.count))) }
        return Data(bigEndian(UInt32(body.count)) + kind + body + bigEndian(crc))
    }

    static func deflate(_ bytes: [UInt8]) -> [UInt8] {
        var size = compressBound(uLong(bytes.count))
        var output = [UInt8](repeating: 0, count: Int(size))
        _ = compress2(&output, &size, bytes, uLong(bytes.count), 9)
        return Array(output.prefix(Int(size)))
    }

    static func image(width: Int, height: Int, colorType: UInt8, depth: UInt8, rows: [[UInt8]] = [],
                      stream: [UInt8]? = nil, interlace: UInt8 = 0, before: [Data] = [], after: [Data] = [],
                      splitIDATWith separator: Data? = nil) -> Data {
        let header = bigEndian(UInt32(width)) + bigEndian(UInt32(height)) + [depth, colorType, 0, 0, interlace]
        var png = Data([137, 80, 78, 71, 13, 10, 26, 10]) + chunk("IHDR", header)
        before.forEach { png += $0 }
        let compressed = stream ?? deflate(rows.flatMap { $0 })
        if let separator {
            let middle = compressed.count / 2
            png += chunk("IDAT", Array(compressed[..<middle])) + separator + chunk("IDAT", Array(compressed[middle...]))
        } else {
            png += chunk("IDAT", compressed)
        }
        after.forEach { png += $0 }
        return png + chunk("IEND", [])
    }

    /// Little-endian TIFF with a single IFD0 Orientation entry.
    static func tiff(orientation: UInt16, type: UInt16 = 3) -> [UInt8] {
        var entry: [UInt8] = [0x12, 0x01] + littleEndian(type) + [1, 0, 0, 0]
        entry += type == 5 ? [26, 0, 0, 0] : littleEndian(orientation) + [0, 0]
        return [0x49, 0x49, 0x2a, 0, 8, 0, 0, 0, 1, 0] + entry + [0, 0, 0, 0] + [UInt8](repeating: 1, count: 8)
    }

    static func xmp(_ orientation: String) -> Data {
        chunk("iTXt", Array("XML:com.adobe.xmp".utf8) + [0, 0, 0, 0, 0] + Array("tiff:Orientation=\"\(orientation)\"".utf8))
    }

    static let animationControl = chunk("acTL", bigEndian(UInt32(2)) + bigEndian(UInt32(0)))

    static func frameControl(sequence: UInt32, width: UInt32, height: UInt32) -> Data {
        chunk("fcTL", bigEndian(sequence) + bigEndian(width) + bigEndian(height) + [UInt8](repeating: 0, count: 8)
            + [0, 1, 0, 10, 0, 0])
    }

    /// Recomputes every chunk CRC so corruption reaches inflate and unfiltering.
    static func repairingCRCs(_ data: Data) -> Data {
        var bytes = [UInt8](data), offset = 8
        while offset + 12 <= bytes.count {
            let length = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8
                | Int(bytes[offset + 3])
            guard length <= bytes.count - offset - 12 else { break }
            let crc = bytes[(offset + 4)..<(offset + 8 + length)].withContiguousStorageIfAvailable {
                UInt32(crc32(0, $0.baseAddress, UInt32($0.count)))
            } ?? 0
            bytes.replaceSubrange((offset + 8 + length)..<(offset + 12 + length), with: bigEndian(crc))
            offset += length + 12
        }
        return Data(bytes)
    }

    private static func bigEndian(_ value: UInt32) -> [UInt8] { withUnsafeBytes(of: value.bigEndian, Array.init) }
    private static func littleEndian(_ value: UInt16) -> [UInt8] { withUnsafeBytes(of: value.littleEndian, Array.init) }
}

enum SuperImageTestJPEG {
    /// Offset of the first `marker` segment before the first scan.
    static func segment(_ marker: UInt8, in data: Data) -> Int? {
        var offset = 2
        let bytes = [UInt8](data)
        while offset + 4 <= bytes.count, bytes[offset] == 0xff {
            if bytes[offset + 1] == marker { return offset }
            if bytes[offset + 1] == 0xda { return nil }
            offset += 2 + (Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3]))
        }
        return nil
    }

    static func removing(_ marker: UInt8, from data: Data) -> Data {
        guard let start = segment(marker, in: data) else { return data }
        let length = Int(data[start + 2]) << 8 | Int(data[start + 3])
        var copy = data
        copy.removeSubrange(start..<(start + 2 + length))
        return copy
    }
}

extension NemotronSuperImageDecodeTests {
    /// One picture encoded by ImageIO as PNG and as JPEG.
    static func encoded(_ type: UTType, width: Int = 256, height: Int = 256,
                        fill: (red: CGFloat, green: CGFloat, blue: CGFloat) = (1, 0, 0)) throws -> Data {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: fill.red, green: fill.green, blue: fill.blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// The same picture as PNG and JPEG normalizes to nearly the same tower
    /// input, inside the range the reference normalization can produce.
    @Test func samePictureAsPNGAndJPEGNormalizesAlike() throws {
        let png = try NemotronSuperImageDecode.prepare(Self.encoded(.png), orientation: .applyEXIF)
        let jpeg = try NemotronSuperImageDecode.prepare(Self.encoded(.jpeg), orientation: .applyEXIF)
        #expect(png.grid == jpeg.grid && png.normalizedCHW.count == jpeg.normalizedCHW.count)
        let difference = zip(png.normalizedCHW, jpeg.normalizedCHW).map { abs($0 - $1) }.max() ?? .infinity
        #expect(difference < 0.05, "max |png - jpeg| = \(difference)")
        // (x / 255 - mean) / std for x in 0...255, per channel.
        let mean: [Float] = [0.48145466, 0.4578275, 0.40821073]
        let std: [Float] = [0.26862954, 0.26130258, 0.27577711]
        let plane = png.normalizedCHW.count / 3
        for prepared in [png, jpeg] {
            for channel in 0..<3 {
                let values = prepared.normalizedCHW[(channel * plane)..<((channel + 1) * plane)]
                #expect(values.allSatisfy { $0.isFinite && $0 >= -mean[channel] / std[channel] - 1e-3
                    && $0 <= (1 - mean[channel]) / std[channel] + 1e-3 }, "channel \(channel)")
            }
        }
    }
}

struct SuperImageSplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9e37_79b9_7f4a_7c15
        var value = state
        value = (value ^ (value >> 30)) &* 0xbf58_476d_1ce4_e5b9
        value = (value ^ (value >> 27)) &* 0x94d0_49bb_1331_11eb
        return value ^ (value >> 31)
    }
}
