// Copyright © 2026 Eigen Labs.
import Foundation
import Testing
@testable import ProviderCore

/// Inflate work of compressed PNG chunks is bounded per image, whatever their
/// keyword, corruption or encoding. Pillow 12.2.0 accepts every image refused
/// here: its limits count only text it stores.
struct NemotronSuperPNGTextTests {
    private typealias Failure = NemotronSuperImageDecode.Failure
    private static let mebibyte = 1024 * 1024

    private static func image(_ chunks: [Data]) -> Data {
        SuperImageTestPNG.image(width: 2, height: 1, colorType: 0, depth: 8, rows: [[0, 7, 9]], before: chunks)
    }

    private static func decodes(_ chunks: [Data]) throws -> Bool {
        try NemotronSuperImageDecode.decode(image(chunks), orientation: .applyEXIF).rgb == [7, 7, 7, 9, 9, 9]
    }

    /// Each kind inflates 1 MiB that Pillow neither stores nor counts.
    @Test func uncountedChunksShareTheImageInflateBudget() throws {
        let stream = SuperImageTestPNG.deflate([UInt8](repeating: 32, count: Self.mebibyte))
        var corrupt = stream
        corrupt[corrupt.count - 1] ^= 1  // Adler-32 mismatch after the full output
        let kinds: [(String, Data)] = [
            ("unkeyed zTXt", SuperImageTestPNG.chunk("zTXt", [0, 0] + stream)),
            ("corrupt zTXt", SuperImageTestPNG.chunk("zTXt", Array("Title".utf8) + [0, 0] + corrupt)),
            ("iTXt with a non-UTF-8 language", SuperImageTestPNG.chunk("iTXt",
                Array("Desc".utf8) + [0, 1, 0, 0xff, 0, 0] + stream)),
            ("corrupt compressed iTXt", SuperImageTestPNG.chunk("iTXt",
                Array("Desc".utf8) + [0, 1, 0, 0, 0] + corrupt)),
        ]
        let budget = NemotronSuperPNGText.maximumInflatedBytes / Self.mebibyte
        #expect(budget == 16)
        for (name, chunk) in kinds {
            let within = [Data](repeating: chunk, count: budget)
            #expect(try Self.decodes(within), "\(name)")
            #expect(throws: Failure.sizeLimit, "\(name)") {
                try NemotronSuperImageDecode.inspect(Self.image(within + [chunk]), orientation: .applyEXIF)
            }
        }
        // ICC and stored text share the same budget, to the byte.
        let profile = SuperImageTestPNG.chunk("iCCP", Array("icc".utf8) + [0, 0] + stream)
        let text = (0..<15).map { SuperImageTestPNG.chunk("zTXt", Array("T\($0)".utf8) + [0, 0] + stream) }
        let byte = SuperImageTestPNG.chunk("zTXt", Array("B".utf8) + [0, 0] + SuperImageTestPNG.deflate([66]))
        #expect(try Self.decodes([profile] + text))
        #expect(throws: Failure.sizeLimit) {
            try NemotronSuperImageDecode.inspect(Self.image([profile] + text + [byte]), orientation: .applyEXIF)
        }
    }

    /// The bomb: thousands of 1 KiB unkeyed zTXt chunks, each inflating to
    /// 1 MiB, were inflated in full (2 GiB per parse, twice) and accepted.
    @Test func manySmallUnkeyedChunksAreRefused() throws {
        let chunk = SuperImageTestPNG.chunk("zTXt", [0, 0]
            + SuperImageTestPNG.deflate([UInt8](repeating: 0, count: Self.mebibyte)))
        #expect(chunk.count < 2048)
        let bomb = Self.image([Data](repeating: chunk, count: 2048))
        #expect(throws: Failure.sizeLimit) { try NemotronSuperImageDecode.inspect(bomb, orientation: .applyEXIF) }
        #expect(throws: Failure.sizeLimit) {
            try NemotronSuperImageDecode.prepare(bomb, orientation: .applyEXIF)
        }
    }

    @Test func compressedChunkCountIsCapped() throws {
        let cap = NemotronSuperPNGText.maximumCompressedChunks
        #expect(cap == 64)
        let corrupt: [UInt8] = [0x78, 0x9c, 0xff, 0xff, 0xff]
        let kinds: [(String, Data)] = [
            ("zTXt", SuperImageTestPNG.chunk("zTXt", Array("T".utf8) + [0, 0] + SuperImageTestPNG.deflate([65]))),
            ("corrupt unkeyed zTXt", SuperImageTestPNG.chunk("zTXt", [0, 0] + corrupt)),
            ("compressed iTXt", SuperImageTestPNG.chunk("iTXt",
                Array("Desc".utf8) + [0, 1, 0, 0, 0] + SuperImageTestPNG.deflate([65]))),
        ]
        for (name, chunk) in kinds {
            #expect(try Self.decodes([Data](repeating: chunk, count: cap)), "\(name)")
            #expect(throws: Failure.sizeLimit, "\(name)") {
                try NemotronSuperImageDecode.inspect(Self.image([Data](repeating: chunk, count: cap + 1)),
                                                     orientation: .applyEXIF)
            }
        }
        // Uncompressed text and empty streams inflate nothing and are not counted.
        let plain = SuperImageTestPNG.chunk("tEXt", Array("T".utf8) + [0, 65])
        let empty = SuperImageTestPNG.chunk("zTXt", Array("E".utf8) + [0, 0])
        #expect(try Self.decodes([Data](repeating: plain, count: cap) + [Data](repeating: empty, count: cap)
            + [Data](repeating: kinds[0].1, count: cap)))
    }

    /// One z_stream serves every chunk: a corrupt and a truncated stream
    /// before the XMP packet must not leak state into its inflate.
    @Test func eachChunkInflatesFromAResetStream() throws {
        let corrupt = SuperImageTestPNG.chunk("zTXt", Array("A".utf8) + [0, 0, 0x78, 0x9c, 0xff, 0xff, 0xff])
        let truncated = SuperImageTestPNG.chunk("zTXt", Array("B".utf8) + [0, 0]
            + SuperImageTestPNG.deflate([UInt8](repeating: 32, count: 1000)).dropLast(6))
        let xmp = SuperImageTestPNG.chunk("zTXt", Array("XML:com.adobe.xmp".utf8) + [0, 0]
            + SuperImageTestPNG.deflate(Array("<x tiff:Orientation=\"6\"/>".utf8)))
        let raster = try NemotronSuperImageDecode.decode(Self.image([corrupt, truncated, xmp]), orientation: .applyEXIF)
        #expect(raster.width == 1 && raster.height == 2 && raster.rgb == [7, 7, 7, 9, 9, 9])
    }
}
