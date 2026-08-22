// Copyright © 2026 Eigen Labs.
//
// Regression tests for the v0.8.7 vision-prefill process kill.
//
// A Mac Studio M2 Ultra serving `qwen3.6-35b-a3b-vl-mtp-mxfp8` died 8 times in
// 9 hours with:
//
//   MLX/ErrorHandler.swift:345: Fatal error: [metal::malloc] Attempting to
//   allocate 298090824192 bytes which is greater than the maximum allowed
//   buffer size of 41747087360 bytes.
//
// 298,090,824,192 = 386,064² × 2 — the Qwen3-VL vision tower's dense
// `ones([1, N, N])` bf16 attention mask over the CONCATENATED patch stream of
// every image in one request. These tests pin the arithmetic that predicts it,
// the per-image slicing that stops the request from ever producing it, and the
// MLX-fault translation that keeps a residual fault from killing the process.
//
// All pure arithmetic: no GPU, no weights, no network.

import Foundation
import MLX
import MLXLMCommon
import Testing

@testable import ProviderCore

/// The two numbers from the production crash report.
private let m2UltraMaxBufferBytes = 41_747_087_360
private let crashRequestedBytes: UInt64 = 298_090_824_192
/// `sqrt(298_090_824_192 / 2)` — the request's total patch count.
private let crashPatchCount = 386_064
/// One image at Qwen3-VL's default `max_pixels` (16384 · 28 · 28 pixels over
/// 14×14 patches) — the largest single image the processor can emit.
private let maxResolutionImagePatches = 65_536

private func limits(
    maxBufferBytes: Int = m2UltraMaxBufferBytes,
    operatorMaxPatches: Int? = nil
) -> VisionTowerBudget.Limits {
    VisionTowerBudget.Limits(
        maxBufferBytes: maxBufferBytes,
        maskElementBytes: VisionTowerBudget.maskElementBytes,
        operatorMaxPatches: operatorMaxPatches)
}

@Suite("VisionTowerBudget arithmetic")
struct VisionTowerBudgetArithmeticTests {

    @Test("integer square root is the exact floor, including past 2^53")
    func integerSquareRootIsExact() {
        #expect(VisionTowerBudget.integerSquareRoot(0) == 0)
        #expect(VisionTowerBudget.integerSquareRoot(1) == 1)
        #expect(VisionTowerBudget.integerSquareRoot(3) == 1)
        #expect(VisionTowerBudget.integerSquareRoot(4) == 2)
        #expect(VisionTowerBudget.integerSquareRoot(8) == 2)
        #expect(VisionTowerBudget.integerSquareRoot(9) == 3)
        #expect(VisionTowerBudget.integerSquareRoot(24) == 4)
        // Past 2^53, where `Double(v).squareRoot()` alone can round UP and
        // hand back a bound Metal would refuse.
        let big: UInt64 = 1 << 60
        #expect(VisionTowerBudget.integerSquareRoot(big) == 1 << 30)
        #expect(VisionTowerBudget.integerSquareRoot(big - 1) == (1 << 30) - 1)
        #expect(VisionTowerBudget.integerSquareRoot(.max) == Int(UInt32.max))
    }

    @Test("mask bytes reproduce the production crash number exactly")
    func maskBytesMatchTheCrash() {
        #expect(
            VisionTowerBudget.maskBytes(patches: crashPatchCount, elementBytes: 2)
                == crashRequestedBytes)
    }

    @Test("mask bytes saturate instead of trapping")
    func maskBytesSaturate() {
        #expect(VisionTowerBudget.maskBytes(patches: 0, elementBytes: 2) == 0)
        #expect(VisionTowerBudget.maskBytes(patches: -4, elementBytes: 2) == 0)
        #expect(VisionTowerBudget.maskBytes(patches: Int.max, elementBytes: 2) == .max)
    }

    @Test("patch counts come from the grid product and reject overflow")
    func patchCounts() {
        #expect(VisionTowerBudget.patchCount(THW(1, 256, 256)) == 65_536)
        #expect(VisionTowerBudget.patchCount(THW(3, 32, 32)) == 3_072)
        #expect(VisionTowerBudget.patchCount(THW(1, Int.max, 2)) == nil)
        #expect(VisionTowerBudget.totalPatchCount([THW(1, 4, 4), THW(2, 4, 4)]) == 48)
        #expect(VisionTowerBudget.totalPatchCount([]) == 0)
        #expect(
            VisionTowerBudget.totalPatchCount([THW(1, Int.max, 1), THW(1, Int.max, 1)]) == nil)
    }

    @Test("the M2 Ultra admits at most 144,476 patches in one tower call")
    func maxAdmissiblePatchesOnM2Ultra() throws {
        let ceiling = try #require(VisionTowerBudget.maxAdmissiblePatches(limits()))
        #expect(ceiling == 144_476)
        // The bound is tight in both directions against Metal's own check.
        #expect(
            VisionTowerBudget.maskBytes(patches: ceiling, elementBytes: 2)
                <= UInt64(m2UltraMaxBufferBytes))
        #expect(
            VisionTowerBudget.maskBytes(patches: ceiling + 1, elementBytes: 2)
                > UInt64(m2UltraMaxBufferBytes))
    }

    @Test("an unknown device limit fails open rather than refusing all media")
    func unknownDeviceLimitFailsOpen() {
        let unknown = limits(maxBufferBytes: 0)
        #expect(VisionTowerBudget.maxAdmissiblePatches(unknown) == nil)
        #expect(
            VisionTowerBudget.admit(patches: crashPatchCount, subject: "x", limits: unknown)
                == .admit)
    }

    @Test("the operator ceiling can only lower the device bound")
    func operatorCeilingIsLowerOnly() throws {
        let tightened = try #require(
            VisionTowerBudget.maxAdmissiblePatches(limits(operatorMaxPatches: 4_096)))
        #expect(tightened == 4_096)
        // A ceiling above the device bound is ignored: the min() keeps Metal's.
        let loosened = try #require(
            VisionTowerBudget.maxAdmissiblePatches(limits(operatorMaxPatches: 10_000_000)))
        #expect(loosened == 144_476)
    }

    @Test("the operator ceiling only parses positive integers")
    func operatorCeilingParsing() {
        let read = { (value: String) in
            VisionTowerBudget.operatorPatchCeiling(
                environment: ["DARKBLOOM_VISION_MAX_TOWER_PATCHES": value])
        }
        #expect(read("8192") == 8_192)
        #expect(read("0") == nil)
        #expect(read("-1") == nil)
        #expect(read("many") == nil)
        #expect(VisionTowerBudget.operatorPatchCeiling(environment: [:]) == nil)
    }
}

@Suite("VisionTowerBudget admission — the reported incident")
struct VisionTowerBudgetIncidentTests {

    /// The whole fix in one assertion: the batched call the provider used to
    /// make is refused, and every image of that SAME request is admitted once
    /// the tower is driven per image.
    @Test("batching six max-resolution images overflows; per-image does not")
    func perImageRemovesTheAggregateBlowup() {
        let grids = Array(repeating: THW(1, 256, 256), count: 6)
        let aggregate = VisionTowerBudget.totalPatchCount(grids)
        #expect(aggregate == 6 * maxResolutionImagePatches)

        // Before: one tower call over the concatenated stream.
        guard case .reject(let reason) = VisionTowerBudget.admit(
            grids: grids, subject: "this request", limits: limits())
        else {
            Issue.record("batched six-image call must be refused on an M2 Ultra")
            return
        }
        #expect(reason.contains("393216"))
        #expect(reason.contains("144476"))

        // After: one tower call per image.
        for (index, grid) in grids.enumerated() {
            let subject = EngineV2VisionPrefill.imageSubject(index: index, of: grids.count)
            #expect(
                VisionTowerBudget.admit(grids: [grid], subject: subject, limits: limits())
                    == .admit)
        }
    }

    @Test("the crash's own patch count is refused with both numbers in the reason")
    func crashPatchCountIsRefused() {
        guard case .reject(let reason) = VisionTowerBudget.admit(
            patches: crashPatchCount, subject: "image 1 of 6", limits: limits())
        else {
            Issue.record("the production crash's patch count must be refused")
            return
        }
        #expect(reason.contains("image 1 of 6"))
        #expect(reason.contains("\(crashPatchCount)"))
        #expect(reason.contains("277.6 GiB"))
        #expect(reason.contains("38.9 GiB"))
    }

    @Test("two max-resolution images already overflow when batched")
    func twoImagesAlreadyOverflow() {
        // 2 × 65,536 = 131,072 patches → 32 GiB mask, still under the buffer
        // cap; 3 × 65,536 = 196,608 → 72 GiB, over it. The reported 40.5 GiB
        // refusal sits between the two, which is why the crashes started as
        // soon as multi-image traffic did.
        let two = Array(repeating: THW(1, 256, 256), count: 2)
        let three = Array(repeating: THW(1, 256, 256), count: 3)
        #expect(VisionTowerBudget.admit(grids: two, subject: "two", limits: limits()) == .admit)
        guard case .reject = VisionTowerBudget.admit(
            grids: three, subject: "three", limits: limits())
        else {
            Issue.record("three max-resolution images must be refused when batched")
            return
        }
    }

    @Test("ordinary images stay far under the bound")
    func ordinaryImagesAdmit() {
        // A ~1024×1024 photo resolves to a 72×72 patch grid — 5,184 patches,
        // a 51 MiB mask. Three orders of magnitude of headroom.
        let grid = THW(1, 72, 72)
        #expect(
            VisionTowerBudget.admit(grids: [grid], subject: "photo", limits: limits()) == .admit)
        #expect(
            VisionTowerBudget.maskBytes(patches: 5_184, elementBytes: 2) < UInt64(64 << 20))
    }

    @Test("an unrepresentable grid is refused, never silently truncated")
    func overflowingGridIsRefused() {
        guard case .reject(let reason) = VisionTowerBudget.admit(
            grids: [THW(1, Int.max, 4)], subject: "image 1 of 1", limits: limits())
        else {
            Issue.record("an overflowing grid must be refused")
            return
        }
        #expect(reason.contains("unrepresentable"))
    }
}

@Suite("EngineV2VisionPrefill per-image pixel slicing")
struct EngineV2VisionPixelRunTests {

    @Test("grids tile the packed pixel tensor in prompt order")
    func runsTileExactly() throws {
        let grids = [THW(1, 4, 4), THW(1, 2, 2), THW(2, 3, 3)]
        let runs = try EngineV2VisionPrefill.imagePixelRuns(grids: grids, totalRows: 16 + 4 + 18)
        #expect(runs == [0 ..< 16, 16 ..< 20, 20 ..< 38])
    }

    @Test("a single image owns the whole tensor")
    func singleImageRun() throws {
        let runs = try EngineV2VisionPrefill.imagePixelRuns(
            grids: [THW(1, 256, 256)], totalRows: 65_536)
        #expect(runs == [0 ..< 65_536])
    }

    @Test("grids that under-cover the tensor are refused")
    func underCoverageIsRefused() {
        #expect(throws: EngineV2VisionPrefillError.self) {
            _ = try EngineV2VisionPrefill.imagePixelRuns(
                grids: [THW(1, 2, 2)], totalRows: 8)
        }
    }

    @Test("grids that over-run the tensor are refused")
    func overRunIsRefused() {
        #expect(throws: EngineV2VisionPrefillError.self) {
            _ = try EngineV2VisionPrefill.imagePixelRuns(
                grids: [THW(1, 2, 2), THW(1, 2, 2)], totalRows: 6)
        }
    }

    @Test("a degenerate grid is refused before it can slice zero rows")
    func degenerateGridIsRefused() {
        #expect(throws: EngineV2VisionPrefillError.self) {
            _ = try EngineV2VisionPrefill.imagePixelRuns(grids: [THW(1, 0, 4)], totalRows: 0)
        }
    }

    @Test("subjects name the image being refused")
    func subjectsAreOperatorReadable() {
        #expect(EngineV2VisionPrefill.imageSubject(index: 0, of: 1) == "this image")
        #expect(EngineV2VisionPrefill.imageSubject(index: 3, of: 6) == "image 4 of 6")
    }
}

@Suite("EngineV2VisionPrefill MLX fault translation")
struct EngineV2VisionMLXFaultTests {

    @Test("the production metal::malloc message yields both byte counts")
    func metalMallocMessageIsParsed() {
        let message =
            "[metal::malloc] Attempting to allocate 298090824192 bytes which is greater than "
            + "the maximum allowed buffer size of 41747087360 bytes."
        guard case .towerAllocationRefused(let requested, let limit) =
            EngineV2VisionPrefill.visionPrefillError(for: .caught(message))
        else {
            Issue.record("a metal::malloc refusal must carry its two byte counts")
            return
        }
        #expect(requested == crashRequestedBytes)
        #expect(limit == UInt64(m2UltraMaxBufferBytes))
    }

    @Test("an unrelated MLX fault degrades to a content-free stage label")
    func unrelatedFaultIsStageOnly() {
        guard case .towerFault =
            EngineV2VisionPrefill.visionPrefillError(for: .caught("broadcast shapes 2,5 3,5"))
        else {
            Issue.record("a non-allocation MLX fault must not claim to be one")
            return
        }
    }

    @Test("a malformed allocation message does not invent numbers")
    func malformedAllocationMessageIsStageOnly() {
        guard case .towerFault =
            EngineV2VisionPrefill.visionPrefillError(for: .caught("[metal::malloc] refused"))
        else {
            Issue.record("an unparseable allocation message must degrade to a stage label")
            return
        }
    }

    @Test("integer extraction takes the first two runs and stops")
    func integerExtraction() throws {
        let pair = try #require(EngineV2VisionPrefill.firstTwoIntegers(in: "a 12 b 34 c 56"))
        #expect(pair.0 == 12)
        #expect(pair.1 == 34)
        #expect(EngineV2VisionPrefill.firstTwoIntegers(in: "only 7") == nil)
        // A run flush at end-of-string still counts.
        let trailing = try #require(EngineV2VisionPrefill.firstTwoIntegers(in: "7 then 8"))
        #expect(trailing.0 == 7)
        #expect(trailing.1 == 8)
    }

    @Test("the refusal description reports bytes without any request content")
    func refusalDescriptionIsContentFree() {
        let error = EngineV2VisionPrefillError.towerAllocationRefused(
            requestedBytes: crashRequestedBytes, limitBytes: UInt64(m2UltraMaxBufferBytes))
        let text = String(describing: error)
        #expect(text.contains("298090824192"))
        #expect(text.contains("41747087360"))
    }
}
