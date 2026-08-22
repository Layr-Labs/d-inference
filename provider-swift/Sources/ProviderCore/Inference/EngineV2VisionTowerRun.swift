// Copyright © 2026 Eigen Labs.
//
// Vision-tower invocation for the v2 media prefill.
//
// `EngineV2VisionPrefill` owns orchestration (decode → processor → tower →
// span carving); this file owns exactly one step of it: turning a processor's
// packed pixels + grids into one soft-token embedding array per image, for
// each supported VLM family.
//
// The two families need opposite handling, and getting that wrong is what
// produced the v0.8.7 provider crashes:
//
//   * Gemma 4's SigLIP tower already runs ONE image per forward pass
//     (`visionFeatureList` loops `0 ..< B` internally) with a fixed patch
//     count per image, so its activation cost is linear in the image count.
//
//   * Qwen3-VL's tower runs whatever it is handed as ONE sequence, with an
//     N×N attention intermediate over the CONCATENATED patch stream (a dense
//     `ones([1, N, N])` mask, plus a `[1, H, N, N]` score tensor whenever MLX
//     cannot fuse the head dim — see `VisionTowerBudget`). Handing it the
//     whole request made peak memory quadratic in the total image count: the
//     reported node asked Metal for 277.6 GiB against a 38.9 GiB per-buffer
//     limit, MLX's default error handler called `fatalError`, and the daemon
//     died with every co-batched request on it.
//
// So the Qwen path here drives the tower ONE IMAGE AT A TIME and evaluates
// each image's features before starting the next. Attention is block-diagonal
// per image already, and every other stage of the tower (patch embed,
// positional interpolation, rotary coordinates, layer norms, patch merge) is
// per-token or per-grid, so a per-image call is MATHEMATICALLY equivalent to
// the batched one — it only refuses to build the cross-image half of the
// mask, which was always zeros doing nothing. (Bitwise equality is not
// guaranteed: SDPA's reduction shape changes with N, so float reduction order
// can differ.) Peak attention bytes go from `(Σᵢ nᵢ)²` to `maxᵢ nᵢ²`.
//
// Each image is also checked for MLX faults immediately after its `eval`.
// `MLX.withError`'s handler RECORDS and RETURNS — the C++ op yields a
// degenerate array and Swift keeps going — so without a per-image check a
// failed image would be followed by n−1 more full tower passes on a GPU that
// just refused an allocation, all while holding the model container's lock,
// and any later Swift throw would mask the allocation error entirely.

import Foundation
import MLX
import MLXLMCommon
import MLXVLM

extension EngineV2VisionPrefill {

    /// The pixel rows belonging to each grid in a processor's packed image
    /// tensor, in grid order.
    ///
    /// `QwenVL.patchify` emits `[t·h·w, patchDim]` per image (temporal padding
    /// happens inside it and is already reflected in `gridT`) and the
    /// processor concatenates them along axis 0, so grid `i` owns a contiguous
    /// run of `grid.product` rows. Pure arithmetic — no MLX, fully
    /// unit-testable.
    ///
    /// Throws when a grid is degenerate or when the runs do not tile `totalRows`
    /// exactly; either means the processor and the tower disagree about the
    /// request's shape, and slicing on a disagreement would silently feed one
    /// image's pixels into another image's grid.
    static func imagePixelRuns(grids: [THW], totalRows: Int) throws -> [Range<Int>] {
        var runs: [Range<Int>] = []
        runs.reserveCapacity(grids.count)
        var offset = 0
        for (index, grid) in grids.enumerated() {
            guard let rows = VisionTowerBudget.patchCount(grid), rows > 0 else {
                throw EngineV2VisionPrefillError.invalidVisionGrid(mediaIndex: index)
            }
            let (end, overflow) = offset.addingReportingOverflow(rows)
            guard !overflow, end <= totalRows else {
                throw EngineV2VisionPrefillError.visionPixelRunMismatch(
                    expected: totalRows, actual: overflow ? Int.max : end)
            }
            runs.append(offset ..< end)
            offset = end
        }
        guard offset == totalRows else {
            throw EngineV2VisionPrefillError.visionPixelRunMismatch(
                expected: totalRows, actual: offset)
        }
        return runs
    }

    /// The N² buffer multiple this wrapper's vision tower will allocate, read
    /// from the model's own config against MLX's kernel-selection rule.
    static func qwenAttentionHeadFactor(_ wrapper: MLXVLM.Qwen35MoE) -> Int {
        let vision = wrapper.config.visionConfiguration
        return VisionTowerBudget.attentionHeadFactor(
            hiddenSize: vision.hiddenSize, numHeads: vision.numHeads)
    }

    /// One `[1, softTokens, textHidden]` embedding per image, in prompt order,
    /// produced by driving the Qwen3-VL tower once per image.
    ///
    /// Each image is admitted against the device's Metal buffer ceiling BEFORE
    /// its graph is built (`VisionTowerBudget`), and evaluated — and checked
    /// for MLX faults — before the next image's graph is built, so peak device
    /// memory is one image's tower and a fault stops the loop where it happens.
    static func qwenPerImageVisionFeatures(
        wrapper: MLXVLM.Qwen35MoE,
        pixels: MLXArray,
        grids: [THW],
        towerLimits: VisionTowerBudget.Limits,
        mlxErrors: MLX.ErrorBox
    ) throws -> [MLXArray] {
        guard !grids.isEmpty else {
            throw EngineV2VisionPrefillError.emptyVisionFeatures(kind: .image)
        }
        let runs = try imagePixelRuns(grids: grids, totalRows: pixels.dim(0))
        let limits = towerLimits.withHeadFactor(qwenAttentionHeadFactor(wrapper))

        var features: [MLXArray] = []
        features.reserveCapacity(grids.count)
        for (index, grid) in grids.enumerated() {
            switch VisionTowerBudget.admit(
                grids: [grid],
                subject: Self.imageSubject(index: index, of: grids.count),
                limits: limits)
            {
            case .admit:
                break
            case .reject(let reason):
                // Refuse RETRIABLY. The bound is `MTLDevice.maxBufferLength`,
                // which scales with the machine, so the same request can
                // succeed on a larger node — the coordinator's pre-content
                // failover is the right place to find one. A 4xx here would
                // tell the caller their image is invalid when it is only too
                // large for THIS box.
                throw EngineV2VisionPrefillError.towerBudgetExceeded(reason)
            }

            let single = try wrapper.visionFeatures(
                imagePixels: pixels[runs[index], 0...], imageGrids: [grid])
            guard single.ordered.count == 1 else {
                throw EngineV2VisionPrefillError.emptyVisionFeatures(kind: .image)
            }
            let embedding = single.ordered[0].features
            // Materialize before building the next image's graph. Without this
            // every image's attention buffer would be live in one `eval`,
            // restoring the aggregate peak this loop exists to remove.
            eval(embedding)
            // And stop HERE if MLX refused: the recorded error would otherwise
            // survive only until some later Swift throw overwrote the story.
            try EngineV2VisionPrefill.throwIfMLXFaulted(mlxErrors)
            features.append(embedding)
        }
        return features
    }

    /// Content-free subject for a rejection message ("image 2 of 5").
    static func imageSubject(index: Int, of count: Int) -> String {
        count == 1 ? "this image" : "image \(index + 1) of \(count)"
    }
}
