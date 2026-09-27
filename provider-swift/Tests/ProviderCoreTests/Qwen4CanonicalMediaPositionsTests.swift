// Copyright © 2026 Eigen Labs.

import Testing
@testable import ProviderCore

@Suite("Qwen4 canonical media text-tail proof")
struct Qwen4CanonicalMediaPositionsTests {
    private let spans = [1 ..< 2, 3 ..< 4]

    @Test("canonical append retains every common position on each axis")
    func appendedTail() {
        for length in [4, 5, 9, 127, 2048] {
            let axes = (0 ..< 3).flatMap { _ in (0 ..< length).map(Int32.init) }
            #expect(Qwen4CanonicalMediaPositions.prefixLength(
                positions: axes, axes: 3, promptLength: length,
                mediaRanges: spans, decodeDelta: 0) == 4)
        }
    }

    @Test("changed tail positions on any axis refuse normalization")
    func noncanonicalTail() {
        for axis in 0 ..< 3 {
            for offset in 4 ..< 9 {
                var values = (0 ..< 3).flatMap { _ in (0 ..< 9).map(Int32.init) }
                values[axis * 9 + offset] += 1
                #expect(Qwen4CanonicalMediaPositions.prefixLength(
                    positions: values, axes: 3, promptLength: 9,
                    mediaRanges: spans, decodeDelta: 0) == nil)
            }
        }
    }

    @Test("negative deltas and Int64 positions retain exact representable tails")
    func signedDeltaAndWidePositions() {
        let values: [Int64] = (0 ..< 3).flatMap { _ in [0, 1, 1, 1, 2, 3, 4] }
        #expect(Qwen4CanonicalMediaPositions.prefixLength(
            positions: values, axes: 3, promptLength: 7,
            mediaRanges: spans, decodeDelta: -2) == 4)
        #expect(Qwen4CanonicalMediaPositions.prefixLength(
            positions: values, axes: 3, promptLength: 7,
            mediaRanges: spans, decodeDelta: -1) == nil)
    }

    @Test("invalid geometry and native decode overflow refuse normalization")
    func invalidGeometry() {
        let values = (0 ..< 3).flatMap { _ in (0 ..< 7).map(Int32.init) }
        for ranges in [[], [(-1) ..< 2], [1 ..< 1], [3 ..< 5, 4 ..< 6], [3 ..< 4, 1 ..< 2], [1 ..< 8]] {
            #expect(Qwen4CanonicalMediaPositions.prefixLength(
                positions: values, axes: 3, promptLength: 7,
                mediaRanges: ranges, decodeDelta: 0) == nil)
        }
        #expect(Qwen4CanonicalMediaPositions.prefixLength(
            positions: values, axes: 2, promptLength: 7,
            mediaRanges: spans, decodeDelta: 0) == nil)
        #expect(Qwen4CanonicalMediaPositions.prefixLength(
            positions: [Int32](), axes: 3, promptLength: Int.max,
            mediaRanges: spans, decodeDelta: 0) == nil)
        #expect(Qwen4CanonicalMediaPositions.prefixLength(
            positions: values, axes: 3, promptLength: 7,
            mediaRanges: spans, decodeDelta: Int32.max) == nil)
    }
}
