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
// That is an N×N attention intermediate in the Qwen3-VL vision tower over the
// CONCATENATED patch stream of every image in one request. Which intermediate
// depends on the head dim: with MLX's fused kernel the peak is the dense
// `ones([1, N, N])` mask (386,064² × 2 bytes); without it MLX materializes the
// score tensor at `[1, H, N, N]` (96,516² × 16 × 2 — the same number, because
// 16 is a perfect square). The budget reads the factor from the model config
// rather than guessing, so both readings are handled.
//
// These pin the arithmetic that predicts it, the per-image slicing that stops
// the request from ever producing it, and the MLX-fault translation that keeps
// a residual fault from killing the process.
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
/// `sqrt(298_090_824_192 / 2)` — the request's patch count under the
/// fused-kernel (mask) reading.
private let crashPatchCount = 386_064
/// One image at the processor's `maxPixels` (16384 · 28 · 28 = 12,845,056)
/// over 16×16 patches — the largest single image `smart_resize` can emit for
/// the shipping Qwen3-VL preprocessor config.
private let maxResolutionImagePatches = 50_176

private func limits(
    maxBufferBytes: Int = m2UltraMaxBufferBytes,
    headFactor: Int = 1,
    operatorMaxPatches: Int? = nil
) -> VisionTowerBudget.Limits {
    VisionTowerBudget.Limits(
        maxBufferBytes: maxBufferBytes,
        attentionElementBytes: VisionTowerBudget.attentionElementBytes,
        headFactor: headFactor,
        operatorMaxPatches: operatorMaxPatches)
}

/// A square grid with (approximately) `patches` patches.
private func grid(patches: Int) -> THW {
    let side = Int(Double(patches).squareRoot().rounded(.down))
    return THW(1, side, side)
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

    @Test("both readings of the production crash number are reproduced exactly")
    func attentionBytesMatchTheCrash() {
        // Fused kernel: the [1, N, N] mask is the peak.
        #expect(
            VisionTowerBudget.attentionBytes(patches: crashPatchCount, bytesPerSquaredPatch: 2)
                == crashRequestedBytes)
        // Fallback: the [1, 16, N, N] score tensor is the peak, at a quarter
        // of the patch count.
        #expect(
            VisionTowerBudget.attentionBytes(patches: 96_516, bytesPerSquaredPatch: 32)
                == crashRequestedBytes)
    }

    @Test("attention bytes saturate instead of trapping")
    func attentionBytesSaturate() {
        #expect(VisionTowerBudget.attentionBytes(patches: 0, bytesPerSquaredPatch: 2) == 0)
        #expect(VisionTowerBudget.attentionBytes(patches: -4, bytesPerSquaredPatch: 2) == 0)
        #expect(VisionTowerBudget.attentionBytes(patches: Int.max, bytesPerSquaredPatch: 2) == .max)
    }

    @Test("patch counts come from the grid product and reject overflow")
    func patchCounts() {
        #expect(VisionTowerBudget.patchCount(THW(1, 224, 224)) == 50_176)
        #expect(VisionTowerBudget.patchCount(THW(3, 32, 32)) == 3_072)
        #expect(VisionTowerBudget.patchCount(THW(1, Int.max, 2)) == nil)
        #expect(VisionTowerBudget.totalPatchCount([THW(1, 4, 4), THW(2, 4, 4)]) == 48)
        #expect(VisionTowerBudget.totalPatchCount([]) == 0)
        #expect(
            VisionTowerBudget.totalPatchCount([THW(1, Int.max, 1), THW(1, Int.max, 1)]) == nil)
    }
}

@Suite("VisionTowerBudget head factor")
struct VisionTowerHeadFactorTests {

    @Test("MLX's fused head dims cost one N² plane")
    func fusedHeadDimsCostOnePlane() {
        for headDim in [64, 80, 128] {
            let heads = 16
            #expect(
                VisionTowerBudget.attentionHeadFactor(
                    hiddenSize: headDim * heads, numHeads: heads) == 1,
                "head dim \(headDim)")
        }
    }

    @Test("a head dim MLX cannot fuse costs one plane PER HEAD")
    func fallbackHeadDimsCostAPlanePerHead() {
        // Qwen3-VL's shipping vision tower: hidden 1152 / 16 heads = 72, which
        // is not in {64, 80, 128}, so MLX materializes [1, 16, N, N].
        #expect(VisionTowerBudget.attentionHeadFactor(hiddenSize: 1152, numHeads: 16) == 16)
        #expect(VisionTowerBudget.attentionHeadFactor(hiddenSize: 1536, numHeads: 16) == 16)
    }

    @Test("a nonsensical config fails closed, never open")
    func nonsensicalConfigFailsClosed() {
        #expect(VisionTowerBudget.attentionHeadFactor(hiddenSize: 0, numHeads: 16) == 16)
        #expect(VisionTowerBudget.attentionHeadFactor(hiddenSize: 1000, numHeads: 16) == 16)
        #expect(VisionTowerBudget.attentionHeadFactor(hiddenSize: 1024, numHeads: 0) == 1)
        #expect(VisionTowerBudget.attentionHeadFactor(hiddenSize: 1024, numHeads: -4) == 1)
    }

    @Test("the head factor tightens the ceiling by exactly its square root")
    func headFactorTightensTheCeiling() throws {
        let fused = try #require(VisionTowerBudget.maxAdmissiblePatches(limits()))
        let fallback = try #require(
            VisionTowerBudget.maxAdmissiblePatches(limits(headFactor: 16)))
        #expect(fused == 144_476)
        #expect(fallback == 36_119)
        #expect(fallback * 4 <= fused && (fallback + 1) * 4 > fused)
    }

    @Test("the limits carrier folds the factor into its per-N² byte cost")
    func limitsFoldTheFactor() {
        #expect(limits(headFactor: 1).bytesPerSquaredPatch == 2)
        #expect(limits(headFactor: 16).bytesPerSquaredPatch == 32)
        #expect(limits().withHeadFactor(16).bytesPerSquaredPatch == 32)
        // A factor below 1 is meaningless and must not widen the bound.
        #expect(limits(headFactor: 0).bytesPerSquaredPatch == 2)
    }
}

@Suite("VisionTowerBudget admission — the reported incident")
struct VisionTowerBudgetIncidentTests {

    /// The whole fix in one assertion: the batched call the provider used to
    /// make is refused, and every image of that SAME request is admitted once
    /// the tower is driven per image.
    @Test("batching six max-resolution images overflows; per-image does not")
    func perImageRemovesTheAggregateBlowup() {
        let grids = Array(repeating: grid(patches: maxResolutionImagePatches), count: 6)
        let aggregate = VisionTowerBudget.totalPatchCount(grids)
        #expect(aggregate == 6 * maxResolutionImagePatches)

        // Before: one tower call over the concatenated stream.
        guard case .reject(let reason) = VisionTowerBudget.admit(
            grids: grids, subject: "this request", limits: limits())
        else {
            Issue.record("batched six-image call must be refused on an M2 Ultra")
            return
        }
        #expect(reason.contains("301056"))
        #expect(reason.contains("144476"))

        // After: one tower call per image.
        for (index, g) in grids.enumerated() {
            let subject = EngineV2VisionPrefill.imageSubject(index: index, of: grids.count)
            #expect(
                VisionTowerBudget.admit(grids: [g], subject: subject, limits: limits())
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

    /// Under the fallback reading, a single max-resolution image genuinely
    /// cannot be served on an M2 Ultra — it needs 80 GiB against a 38.9 GiB
    /// ceiling. The gate must say so rather than let the allocator find out.
    @Test("a max-resolution image on a fallback-kernel tower is refused")
    func fallbackKernelRefusesAMaxResolutionImage() {
        let fallback = limits(headFactor: 16)
        guard case .reject = VisionTowerBudget.admit(
            patches: maxResolutionImagePatches, subject: "this image", limits: fallback)
        else {
            Issue.record("50,176 patches × 16 heads cannot fit a 38.9 GiB buffer")
            return
        }
        // The same image is fine once it is under the tighter ceiling.
        #expect(
            VisionTowerBudget.admit(patches: 36_119, subject: "this image", limits: fallback)
                == .admit)
    }

    @Test("ordinary images stay far under the bound on either kernel")
    func ordinaryImagesAdmit() {
        // A ~1150×1150 photo resolves to a 72×72 patch grid — 5,184 patches.
        let photo = THW(1, 72, 72)
        for factor in [1, 16] {
            #expect(
                VisionTowerBudget.admit(
                    grids: [photo], subject: "photo", limits: limits(headFactor: factor))
                    == .admit,
                "head factor \(factor)")
        }
        #expect(
            VisionTowerBudget.attentionBytes(patches: 5_184, bytesPerSquaredPatch: 32)
                < UInt64(1 << 30))
    }

    @Test("an unknown device limit fails open rather than refusing all media")
    func unknownDeviceLimitFailsOpen() {
        let unknown = limits(maxBufferBytes: 0)
        #expect(VisionTowerBudget.maxAdmissiblePatches(unknown) == nil)
        #expect(
            VisionTowerBudget.admit(patches: crashPatchCount, subject: "x", limits: unknown)
                == .admit)
    }

    @Test("with only an operator ceiling the reason omits a bogus device limit")
    func reasonOmitsUnknownDeviceLimit() {
        guard case .reject(let reason) = VisionTowerBudget.admit(
            patches: 10_000, subject: "this image",
            limits: limits(maxBufferBytes: 0, operatorMaxPatches: 4_096))
        else {
            Issue.record("an operator ceiling must still refuse")
            return
        }
        #expect(!reason.contains("0.0 GiB"))
        #expect(reason.contains("4096"))
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
            grids: [THW(1, 224, 224)], totalRows: 50_176)
        #expect(runs == [0 ..< 50_176])
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

    /// A recorded MLX fault must surface as OUR error, not the raw `MLXError`
    /// — otherwise the telemetry privacy filter drops the byte counts and the
    /// operator is told only "MLX.MLXError".
    @Test("a recorded fault is translated, not passed through")
    func recordedFaultIsTranslated() {
        #expect(EngineV2VisionPrefill.translatedFault(nil) == nil)

        let recorded = MLX.MLXError.caught(
            "[metal::malloc] Attempting to allocate 100 bytes which is greater than "
                + "the maximum allowed buffer size of 50 bytes.")
        guard let translated = EngineV2VisionPrefill.translatedFault(recorded)
            as? EngineV2VisionPrefillError,
            case .towerAllocationRefused(let requested, let limit) = translated
        else {
            Issue.record("a recorded allocation refusal must translate to our own case")
            return
        }
        #expect(requested == 100)
        #expect(limit == 50)
    }

    @Test("a non-MLX recorded error is passed through unchanged")
    func nonMLXFaultPassesThrough() {
        struct Marker: Error, Equatable {}
        #expect(EngineV2VisionPrefill.translatedFault(Marker()) as? Marker == Marker())
    }
}
