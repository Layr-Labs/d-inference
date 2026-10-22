// Copyright © 2026 Eigen Labs.

import Foundation
import MLXLLM
import MLXLMCommon
import MLXVLM

/// Concurrency and per-request admission of the unpublished Super owner.
extension NemotronSuperLocalBridgeBuilder {
    /// Runtime-policy key: requests the owner serves at once. The plain owner
    /// takes `1`…`64` (the rows of one batched text decode step); the
    /// speculative owner takes `1`…`8` (the requests of one captured verify
    /// window). Default one.
    static let maxConcurrentKey = "DARKBLOOM_NEMOTRON_SUPER_MAX_CONCURRENT"

    /// A malformed or out-of-range value fails the load rather than silently
    /// changing the measured configuration.
    static func concurrentRequests(environment: [String: String], speculates: Bool) throws -> Int {
        guard let raw = environment[maxConcurrentKey]?.trimmingCharacters(in: .whitespaces) else {
            return 1
        }
        let limit = speculates
            ? NemotronHModel.superMTPMaximumWindowRequests : NemotronSuperRecurrentAdapter.decodeRowLimit
        guard let value = Int(raw), (1 ... limit).contains(value) else { throw Failure.invalidConcurrency }
        return value
    }

    /// Fixed bytes each request needs beyond the engine's own (recurrent
    /// generations and any speculation charge): one batched decode row, which
    /// the owner reserves for every configured request
    /// (`NemotronSuperLocalKVBackend.decodeRowsBytes`). Prompt chunks run one
    /// per step, so their activations are the owner's single prefill lane
    /// (`NemotronSuperLocalPrefill`), not a per-request charge. The eager
    /// reference keeps its own bounded tiles and has no row quote.
    static func requestWorkspaceBytes(_ language: NemotronHModel) throws -> Int {
        do {
            // Only the row workspace is used; the KV element width does not enter it.
            return try language.superDecodeCharge(kvElementBytes: 2).rowWorkspace.totalBytes
        } catch NemotronSuperDecodeCharge.Failure.unsupportedExecution {
            return 0
        }
    }

    /// The KV grant cannot serve the configured requests: the bridge carves
    /// each request's fixed bytes (recurrent state, any speculation charge and
    /// the request workspace) plus the minimum KV from it, and
    /// `minimumGrantBytes` is the smallest grant that admits `requests` of them.
    struct UnserviceableGrant: Error, Equatable, CustomStringConvertible {
        let grantBytes: Int
        let minimumGrantBytes: Int
        let fixedRequestBytes: Int
        let requests: Int

        var description: String {
            "KV grant of \(grantBytes) bytes is below the \(minimumGrantBytes)-byte minimum that serves "
                + "\(requests) concurrent request(s) with \(fixedRequestBytes) fixed request bytes each"
        }
    }
}

extension EngineV2Factory.ProductionBuild {
    /// The same build with `bytes` more fixed workspace per request in the
    /// bridge's grant and width arithmetic (`maximumRequestOverheadBytes`);
    /// the owner reserves the bytes themselves as its decode rows.
    func addingSuperRequestWorkspace(_ bytes: Int) throws -> Self {
        let (total, overflow) = fixedRequestBytes.addingReportingOverflow(bytes)
        guard bytes >= 0, !overflow, total < Int.max else {
            throw NemotronSuperLocalBridgeBuilder.Failure.unsupportedSizing
        }
        return .init(engine: engine, fixedRequestBytes: total, kvBackendKind: kvBackendKind,
            kvBackendFallbackReason: kvBackendFallbackReason, pagedPoolDType: pagedPoolDType,
            usesProcessMemoryOwner: usesProcessMemoryOwner,
            mtpAdmissionResolution: mtpAdmissionResolution,
            legacyMTPBytesPerToken: legacyMTPBytesPerToken,
            effectiveMaxConcurrentRequests: effectiveMaxConcurrentRequests,
            kvQuantization: kvQuantization, kvCheckpointQuantization: kvCheckpointQuantization,
            admissionWatermarkFraction: admissionWatermarkFraction)
    }
}

extension EngineV2Bridge {
    /// The refusal of `grantBytes` when this bridge serves fewer than
    /// `requests` at once; nil when it serves them all. Read in one isolated
    /// pass so the report matches the decision.
    func superGrantRefusal(grantBytes: Int, requests: Int)
        -> NemotronSuperLocalBridgeBuilder.UnserviceableGrant? {
        guard effectiveServingConcurrency < requests else { return nil }
        return .init(grantBytes: grantBytes,
            minimumGrantBytes: superMinimumGrantBytes(requests: requests),
            fixedRequestBytes: maximumRequestOverheadBytes() ?? Int.max, requests: requests)
    }

    /// Smallest grant whose admission ceiling holds `requests` requests' fixed
    /// bytes plus the minimum KV: the count `fixedWorkspaceConcurrencyLimit`
    /// admits on this ordinary bridge, plus the engine's checkpoint bank
    /// budget carved from the same grant. Int.max when unprovable.
    func superMinimumGrantBytes(requests: Int) -> Int {
        guard requests > 0, let overhead = maximumRequestOverheadBytes(),
            let engine = ownedEngine as? EngineV2, let admissionWatermarkFraction
        else { return Int.max }
        let (fixed, overflow) = overhead.multipliedReportingOverflow(by: requests)
        guard !overflow else { return Int.max }
        let floor = Self.minimumOrdinaryGrantBytes(fixedRequestBytes: fixed,
            capacityBytes: engine.capacity().kvBytesCapacity,
            admissibleCapacityBytes: engine.admissibleKVBytesCapacity,
            watermarkFraction: admissionWatermarkFraction)
        let bank = engine.hybridPrefixCache?.config.maximumBytes ?? 0
        let (total, bankOverflow) = floor.addingReportingOverflow(bank)
        return floor == Int.max || bankOverflow ? Int.max : total
    }
}
