// Copyright © 2026 Eigen Labs.

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXVLM

/// The video binding's native step over an installed Super owner: the tower
/// over bounded tubelet batches as frames decode, EVS scores of each batch
/// behind the previous batch's last tubelet, pruning of the projected rows,
/// and the kept rows gathered in prompt order. Only projected rows and host
/// scores outlive a batch.
enum NemotronSuperVideoFeatures {
    /// Pruning rate q in [0, 1) of EVS (NVIDIA's serving recipe uses
    /// `NemotronSuperVideoPreprocessing.defaultPruningRate`); `0` keeps every row.
    static let pruningKey = "DARKBLOOM_NEMOTRON_SUPER_VIDEO_PRUNING"
    /// Tubelets per tower call. Four keep one batch's frames, activation and
    /// scoring window, beside every tubelet's rows, inside one largest image's
    /// media charge (`NemotronSuperServingPolicy.videoMediaChargeBytes`).
    static let tubeletBatch = 4

    /// The configured rate; nil when the key holds anything but a rate in [0, 1).
    static func pruningRate(environment: [String: String]) -> Double? {
        guard let raw = environment[pruningKey]?.trimmingCharacters(in: .whitespaces) else {
            return NemotronSuperVideoPreprocessing.defaultPruningRate
        }
        guard let rate = Double(raw), rate.isFinite, rate >= 0, rate < 1 else { return nil }
        return rate
    }

    /// The configured rate, or `invalidVideoPruning`. The load checks it
    /// before its LOAD claim and installation, so a malformed value costs no
    /// install.
    static func validatedPruningRate(environment: [String: String]) throws -> Double {
        guard let rate = pruningRate(environment: environment) else {
            throw NemotronSuperLocalBridgeBuilder.Failure.invalidVideoPruning
        }
        return rate
    }

    /// vLLM's `compute_retained_tokens_count`: the unpruned share of every
    /// row, never fewer than one tubelet's rows; every row when off.
    static func retainedRows(tubelets: Int, rowsPerTubelet: Int, pruningRate: Double) -> Int {
        let total = tubelets * rowsPerTubelet
        guard pruningRate > 0 else { return total }
        return max(rowsPerTubelet, Int(Double(total) * (1 - pruningRate)))
    }

    /// Runs in the installation's native setup with MLX faults recorded and
    /// checked at every evaluation. `live` holds every array a failed fence
    /// must keep: the batch in flight and every retained output.
    static func prepare(installed: NemotronSuperInstallation.Installed, frames: NemotronSuperVideoDecode.Frames,
        prompt: NemotronSuperPromptContract.VideoPrompt, pruningRate: Double, contextLength: Int,
        maximumFeatureBytes: Int, construction: NativeConstructionScope, live: inout [MLXArray]
    ) throws -> EngineV2VisionPrefill.PreparedSubmission {
        typealias Binding = NemotronSuperLocalImageBinding
        let grid = frames.plan.grid
        let tubelets = frames.plan.tubelets
        guard tubelets > 0, grid.tokens > 0, prompt.labels.count == tubelets, maximumFeatureBytes > 0 else {
            throw Binding.Failure.invalidInput
        }
        return try installed.withNativeSetup(construction: construction) {
            (model: NemotronSuperModel) throws -> EngineV2VisionPrefill.PreparedSubmission in
            try MLX.withError { (errors: MLX.ErrorBox) throws -> EngineV2VisionPrefill.PreparedSubmission in
                // The prompt length was admitted for exactly this many rows.
                let retained = retainedRows(tubelets: tubelets, rowsPerTubelet: grid.tokens, pruningRate: pruningRate)
                let prunes = retained < tubelets * grid.tokens
                var batches: [MLXArray] = []
                // EVS scores of tubelets 1..<T, row-major, as the whole-video
                // [T - 1, N] graph orders them.
                var scores: [Float] = []
                var start = 0
                while start < tubelets {
                    try Task.checkCancellation()
                    let count = min(tubeletBatch, tubelets - start)
                    var samples: [Float] = []
                    samples.reserveCapacity(2 * count * grid.width * grid.height * 3)
                    for _ in 0 ..< 2 * count {
                        guard let frame = try frames.next() else {
                            throw NemotronSuperVideoDecode.Failure.inconsistentFrames
                        }
                        samples.append(contentsOf: frame)
                    }
                    let pixels = MLXArray(samples, [2 * count, 3, grid.height, grid.width])
                    samples = []
                    let features = try model.imageComposition.videoFeatures(normalizedFrames: pixels)
                    live.append(pixels)
                    live.append(features)
                    eval(features)
                    try EngineV2VisionPrefill.throwIfMLXFaulted(errors)
                    guard features.ndim == 3, features.dim(0) == count, features.dim(1) == grid.tokens else {
                        throw Binding.Failure.inconsistentVideoFeatures
                    }
                    live.removeAll { $0 === pixels }
                    if prunes {
                        // A token scores against the same position of the
                        // previous tubelet only, so each batch is scored
                        // behind the previous batch's last tubelet and the
                        // first tubelet has no scores.
                        let window = batches.last.map { previous in
                            concatenated([previous[(previous.dim(0) - 1)...], features], axis: 0)
                        } ?? features
                        if window.dim(0) > 1 {
                            // Retained before evaluation, then read to the host.
                            let windowScores = NemotronSuperEVS.dissimilarity(window)
                            live.append(windowScores)
                            eval(windowScores)
                            try EngineV2VisionPrefill.throwIfMLXFaulted(errors)
                            scores.append(contentsOf: windowScores.asArray(Float.self))
                            live.removeAll { $0 === windowScores }
                        }
                    }
                    batches.append(features)
                    start += count
                }
                let rows = batches.count == 1 ? batches[0] : concatenated(batches, axis: 0)
                live.append(rows)
                eval(rows)
                try EngineV2VisionPrefill.throwIfMLXFaulted(errors)
                batches.removeAll()
                live = [rows]
                let kept = prunes
                    ? NemotronSuperEVS.keptPositions(dissimilarity: scores, tubelets: tubelets, tokens: grid.tokens,
                                                     pruningRate: pruningRate)
                    : Array(repeating: Array(0 ..< grid.tokens), count: tubelets)
                guard kept.count == tubelets, kept.reduce(0, { $0 + $1.count }) == retained,
                    kept.allSatisfy({ positions in
                        zip(positions, positions.dropFirst()).allSatisfy { $0 < $1 }
                            && positions.allSatisfy { (0 ..< grid.tokens).contains($0) }
                    })
                else { throw Binding.Failure.inconsistentVideoFeatures }
                let (featureBytes, overflow) = retained.multipliedReportingOverflow(by: rows.dim(2) * 4)
                guard !overflow, featureBytes <= maximumFeatureBytes else { throw Binding.Failure.capacity }
                let tokens: [Int]
                do {
                    tokens = try prompt.tokens(keptCounts: kept.map(\.count), contextLength: contextLength)
                } catch NemotronSuperPromptContract.Failure.contextExceeded {
                    throw Binding.Failure.invalidInput
                }
                guard tokens.allSatisfy({ $0 >= 0 && $0 < model.languageModel.vocabularySize }) else {
                    throw Binding.Failure.invalidInput
                }
                // A fully pruned tubelet keeps its wrappers but has no span.
                let spans = kept.indices.filter { !kept[$0].isEmpty }
                let ranges = try NemotronSuperVisionPreparation.ranges(prompt: tokens.map(Int32.init),
                    featureCounts: spans.map { kept[$0].count })
                let embeddings = spans.map { rows[$0].take(MLXArray(kept[$0]), axis: 0).expandedDimensions(axis: 0) }
                live.append(contentsOf: embeddings)
                eval(embeddings)
                try EngineV2VisionPrefill.throwIfMLXFaulted(errors)
                // The rows are evaluated; a non-finite value would decode as
                // garbage, so the request fails instead of streaming it.
                for embedding in embeddings where !all(isFinite(embedding)).item(Bool.self) {
                    throw Binding.Failure.invalidFeatures
                }
                try EngineV2VisionPrefill.throwIfMLXFaulted(errors)
                return NemotronSuperVisionSubmission.make(promptTokens: tokens, ranges: ranges,
                                                          features: embeddings, mediaKind: .video)
            }
        }
    }
}
