// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLLM
import MLXLMCommon

/// Prompt scheduling and the prefill activation charge of the unpublished
/// Super owner. Every prompt runs in chunks of exactly `chunkTokens` (the last
/// one shorter) whatever else the owner serves, so a request's arithmetic is
/// the same as when it is served alone; a step runs at most one prompt chunk,
/// so one activation allowance (the prefill lane) covers every step, whatever
/// the number of concurrent requests.
enum NemotronSuperLocalPrefill {
    /// Runtime-policy key: prompt chunk tokens, `1` up to the model's
    /// calibrated prefill limit. Default `defaultChunkTokens`.
    static let chunkKey = "DARKBLOOM_NEMOTRON_SUPER_PREFILL_CHUNK"
    /// Runtime-policy key: decode-only steps between two prompt chunks while
    /// requests are decoding, `0`…`maximumDecodeStepsBetweenChunks`. Default 0:
    /// every step may carry a chunk beside the decode rows.
    static let decodeStepsKey = "DARKBLOOM_NEMOTRON_SUPER_DECODE_STEPS_BETWEEN_CHUNKS"
    static let defaultChunkTokens = 2048
    static let maximumDecodeStepsBetweenChunks = 64

    enum Failure: Error, Equatable {
        /// The chunk key is malformed or above the calibrated prefill limit.
        case invalidChunk
        case invalidDecodeSteps
        /// The shared budget cannot hold the prefill lane; nothing was admitted.
        case laneRefused
    }

    struct Policy: Equatable, Sendable {
        let chunkTokens: Int
        let decodeStepsBetweenChunks: Int

        /// A malformed value fails the load rather than silently changing the
        /// measured configuration.
        static func resolve(environment: [String: String], prefillLimit: Int) throws -> Policy {
            var chunk = min(defaultChunkTokens, prefillLimit)
            if let raw = environment[chunkKey]?.trimmingCharacters(in: .whitespaces) {
                guard let value = Int(raw), (1 ... prefillLimit).contains(value) else {
                    throw Failure.invalidChunk
                }
                chunk = value
            }
            var decodeSteps = 0
            if let raw = environment[decodeStepsKey]?.trimmingCharacters(in: .whitespaces) {
                guard let value = Int(raw), (0 ... maximumDecodeStepsBetweenChunks).contains(value)
                else { throw Failure.invalidDecodeSteps }
                decodeSteps = value
            }
            return Policy(chunkTokens: chunk, decodeStepsBetweenChunks: decodeSteps)
        }

        /// The step budget holds one chunk plus every request's decode or
        /// verify row, so neither the budget nor the mixed-step quota ever
        /// shortens a chunk; one prompt row per step keeps the lane sufficient.
        func apply(to config: inout CBv2SchedulerConfig, requests: Int, draftTokens: Int) {
            config.prefillChunkSize = chunkTokens
            config.maxBatchedTokensPerStep = chunkTokens + requests * (1 + draftTokens)
            config.soloPrefillStripeTokens = nil
            config.mixedStepPrefillTokenCap = chunkTokens
            config.maxConcurrentPartialPrefills = 1
            config.maxPrefillRowsPerStep = 1
            config.decodeStepsBetweenPrefillChunks = decodeStepsBetweenChunks
        }
    }

    /// Transient bytes of one prompt chunk beyond resident weights, KV and
    /// recurrent state: the explicit ModelOpt arrays of the heaviest layer
    /// and, for the pinned checkpoint, the SDK's whole-chunk bound measured on
    /// the full model (`prefillActivationBoundBytes`). Synthetic fixtures
    /// charge their own arithmetic quote. Not a measured peak of this run.
    static func laneBytes(_ language: NemotronHModel, chunkTokens: Int, measuredBound: Bool) -> Int {
        let workspace = language.modelOptGraphPrefillWorkspaceBytes(tokens: chunkTokens) ?? 0
        let bound = measuredBound ? pinnedLaneBytes(chunkTokens: chunkTokens) : 0
        return max(workspace, bound)
    }

    /// The pinned checkpoint's lane bound. The builder's lane, the LOAD
    /// claim's lane share, the default bank and the discovery footprint all
    /// read it here, so a new bound reaches each of them.
    static func pinnedLaneBytes(chunkTokens: Int) -> Int {
        NemotronHModel.prefillActivationBoundBytes(tokens: chunkTokens)
    }

    /// The chunk the runtime policy asks for, before the model's calibrated
    /// limit is known: `defaultChunkTokens` without the key, nil when the key
    /// is malformed or outside 1...`maximumContextTokens` (the builder then
    /// refuses it).
    static func requestedChunkTokens(environment: [String: String]) -> Int? {
        guard let raw = environment[chunkKey]?.trimmingCharacters(in: .whitespaces) else {
            return defaultChunkTokens
        }
        guard let value = Int(raw), (1 ... NemotronSuperServingPolicy.maximumContextTokens).contains(value)
        else { return nil }
        return value
    }

    private static let laneSuffix = "-nemotron-super-prefill-lane"

    /// Budget reservation ID of an owner's lane, distinct from request IDs.
    static func laneReservationID() -> String { UUID().uuidString + laneSuffix }

    /// True for a reservation ID made by `laneReservationID()`.
    static func isLaneReservationID(_ id: String) -> Bool { id.hasSuffix(laneSuffix) }
}
