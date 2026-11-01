// Copyright © 2026 Eigen Labs.
import Foundation
import Testing
@testable import ProviderCore

/// Scan parameters and the primary image's extent, from the container alone:
/// ImageIO never sees the synthetic headers here, whose scans carry no
/// entropy-coded data.
struct NemotronSuperJPEGContainerTests {
    private typealias Failure = NemotronSuperImageDecode.Failure

    /// SOFn of a frame whose components (ids 1, 2, ...) are all sampled 1x1.
    private static func frame(_ marker: UInt8, components: Int, width: Int = 8, height: Int = 8) -> [UInt8] {
        [0xff, marker, 0, UInt8(8 + 3 * components), 8, UInt8(height >> 8), UInt8(height & 0xff),
         UInt8(width >> 8), UInt8(width & 0xff), UInt8(components)]
            + (1...components).flatMap { [UInt8($0), 0x11, 0] }
    }

    /// SOS: component ids, spectral selection `start...end`, successive approximation Ah, Al.
    private static func scan(_ components: [UInt8], _ start: UInt8, _ end: UInt8,
                             _ high: UInt8 = 0, _ low: UInt8 = 0) -> [UInt8] {
        [0xff, 0xda, 0, UInt8(6 + 2 * components.count), UInt8(components.count)]
            + components.flatMap { [$0, 0] } + [start, end, high << 4 | low]
    }

    private static func jpeg(_ frame: [UInt8], _ scans: [[UInt8]]) -> Data {
        Data([0xff, 0xd8] + frame + Array(scans.joined()) + [0xff, 0xd9])
    }

    private static func inspect(_ data: Data) throws -> NemotronSuperImageDecode.Quote {
        try NemotronSuperImageDecode.inspect(data, orientation: .applyEXIF)
    }

    @Test func sequentialFramesCodeEachComponentInOneFullScan() throws {
        for marker: UInt8 in [0xc0, 0xc1] {
            let frame = Self.frame(marker, components: 3)
            for scans in [[Self.scan([1, 2, 3], 0, 63)],
                          [Self.scan([2], 0, 63), Self.scan([1, 3], 0, 63)]] {
                #expect(try Self.inspect(Self.jpeg(frame, scans)).format == .jpeg)
            }
            // Pillow decodes the first three with only a libjpeg-turbo warning.
            let refused: [(String, [[UInt8]])] = [
                ("all-zero spectral selection", [Self.scan([1, 2, 3], 0, 0)]),
                ("partial band", [Self.scan([1, 2, 3], 1, 63)]),
                ("successive approximation", [Self.scan([1, 2, 3], 0, 63, 0, 1)]),
                ("a component scanned twice",
                 [Self.scan([1], 0, 63), Self.scan([2, 3], 0, 63), Self.scan([1], 0, 63)]),
                ("a component never scanned", [Self.scan([1, 2], 0, 63)]),
                ("the same scan repeated", Array(repeating: Self.scan([1, 2, 3], 0, 63), count: 500)),
            ]
            for (name, scans) in refused {
                #expect(throws: Failure.invalidHeader, "\(marker) \(name)") {
                    try Self.inspect(Self.jpeg(frame, scans))
                }
            }
        }
    }

    @Test func progressiveScansDecodeNoCoefficientTwice() throws {
        let frame = Self.frame(0xc2, components: 3)
        // libjpeg's jpeg_simple_progression for YCbCr, as the progressive fixtures use.
        let simple = [
            Self.scan([1, 2, 3], 0, 0, 0, 1), Self.scan([1], 1, 5, 0, 2), Self.scan([3], 1, 63, 0, 1),
            Self.scan([2], 1, 63, 0, 1), Self.scan([1], 6, 63, 0, 2), Self.scan([1], 1, 63, 2, 1),
            Self.scan([1, 2, 3], 0, 0, 1, 0), Self.scan([3], 1, 63, 1, 0), Self.scan([2], 1, 63, 1, 0),
            Self.scan([1], 1, 63, 1, 0),
        ]
        #expect(try Self.inspect(Self.jpeg(frame, simple)).format == .jpeg)
        // A progressive image may stop after any scan.
        #expect(try Self.inspect(Self.jpeg(frame, Array(simple.prefix(3)))).format == .jpeg)
        let dc = Self.scan([1, 2, 3], 0, 0, 0, 2)
        let refused: [(String, [[UInt8]])] = [
            ("DC scan with an AC band", [Self.scan([1], 0, 63)]),
            ("AC scan of two components", [dc, Self.scan([1, 2], 1, 63)]),
            ("Ss above Se", [dc, Self.scan([1], 5, 1)]),
            ("Se above 63", [dc, Self.scan([1], 1, 64)]),
            ("Al above 13", [Self.scan([1, 2, 3], 0, 0, 0, 14)]),
            ("refinement dropping two bits", [dc, Self.scan([1, 2, 3], 0, 0, 2, 0)]),
            ("refinement not continuing the previous Al", [dc, Self.scan([1, 2, 3], 0, 0, 1, 0)]),
            ("refinement before a first scan", [Self.scan([1], 1, 63, 1, 0)]),
            ("first scan repeated", [dc, dc]),
            ("overlapping first scans", [dc, Self.scan([1], 1, 5, 0, 1), Self.scan([1], 5, 9, 0, 1)]),
            ("completed coefficient scanned again",
             [Self.scan([1, 2, 3], 0, 0), Self.scan([1, 2, 3], 0, 0, 1, 0)]),
        ]
        for (name, scans) in refused {
            #expect(throws: Failure.invalidHeader, "\(name)") { try Self.inspect(Self.jpeg(frame, scans)) }
        }
    }

    /// The refused CPU bomb: a 64 Mi-pixel progressive frame whose full-band
    /// refinement scan repeats. Each copy is a few bytes and covers every
    /// block of the frame again, and ImageIO's decode cannot be cancelled.
    @Test func repeatedRefinementScansAreRefused() throws {
        let frame = Self.frame(0xc2, components: 1, width: 8192, height: 8192)
        let first = [Self.scan([1], 0, 0), Self.scan([1], 1, 63, 0, 1)]
        let refinement = Self.scan([1], 1, 63, 1, 0)
        #expect(try Self.inspect(Self.jpeg(frame, first + [refinement])).width == 8192)
        #expect(throws: Failure.invalidHeader) {
            try Self.inspect(Self.jpeg(frame, first + Array(repeating: refinement, count: 498)))
        }
    }

    /// ImageIO is given bytes [0, primaryLength): MPO frames and trailers
    /// after the primary EOI, which Pillow never decodes for frame 0, are not
    /// part of the stream it parses.
    @Test func primaryImageEndsAtItsEOI() throws {
        func container(_ data: Data) throws -> NemotronSuperJPEGContainer {
            try data.withUnsafeBytes { try NemotronSuperJPEGContainer.parse($0) }
        }
        let mpo = try NemotronSuperImageFixtures.data("jpeg-mpo.jpeg")
        let primary = try container(mpo).primaryLength
        #expect(primary == 1254 && primary < mpo.count)
        #expect(mpo[primary - 2] == 0xff && mpo[primary - 1] == 0xd9)
        let whole = try NemotronSuperImageDecode.decode(mpo, orientation: .applyEXIF)
        #expect(whole.rgb == (try NemotronSuperImageDecode.decode(mpo.prefix(primary), orientation: .applyEXIF)).rgb)
        let baseline = try NemotronSuperImageFixtures.data("jpeg-420.jpeg")
        #expect(try container(baseline).primaryLength == baseline.count)
        // Fill bytes before EOI belong to the primary image; a trailer does not.
        let filled = Self.jpeg(Self.frame(0xc0, components: 1), [Self.scan([1], 0, 63)])
        let padded = filled.dropLast(2) + Data([0xff, 0xff, 0xd9])
        #expect(try container(padded).primaryLength == padded.count)
        #expect(try container(padded + Data("trailer".utf8)).primaryLength == padded.count)
    }
}
