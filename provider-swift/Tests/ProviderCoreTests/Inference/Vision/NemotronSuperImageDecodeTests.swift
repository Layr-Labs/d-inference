import Foundation
import Testing
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

    @Test func rejectsAlphaAndOversizeBeforeRasterDecode() throws {
        let alpha = try #require(Data(base64Encoded: alphaPNG))
        #expect(throws: NemotronSuperImageDecode.Failure.unsupportedEncoding) {
            try NemotronSuperImageDecode.inspect(alpha, orientation: .preserveRaster)
        }
        let rgb = try #require(Data(base64Encoded: rgbPNG))
        #expect(throws: NemotronSuperImageDecode.Failure.sizeLimit) {
            try NemotronSuperImageDecode.inspect(rgb, orientation: .preserveRaster, maxPixels: 5)
        }
        #expect(throws: NemotronSuperImageDecode.Failure.sizeLimit) {
            try NemotronSuperImageDecode.inspect(rgb, orientation: .preserveRaster, maxEncodedBytes: 1)
        }
        #expect(throws: NemotronSuperImageDecode.Failure.unsupportedEncoding) {
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
