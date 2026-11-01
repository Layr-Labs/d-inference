// Copyright © 2026 Eigen Labs.

import Foundation

/// Attention KV storage of the unpublished Super owner: always the segmented
/// native paged backend (BF16 layer types observed from the loaded model);
/// Super has no contiguous storage. Paged storage is charged to the shared
/// budget by the engine's process-memory owner as segments and recurrent rows
/// materialize, and the bridge reserves no request bytes of its own; the
/// owner therefore reserves every request's decode-row workspace itself, like
/// the prefill lane, from before the first request until native retirement.
enum NemotronSuperLocalKVBackend {
    /// Runtime-policy key, kept so a configuration naming other storage fails
    /// the load instead of being ignored: unset or `paged` serves paged KV.
    static let key = "DARKBLOOM_NEMOTRON_SUPER_KV_BACKEND"

    enum Failure: Error, Equatable {
        /// The key is neither `paged` nor `contiguous`.
        case invalidBackend
        /// The key is `contiguous`, which Super no longer serves.
        case contiguousUnsupported
        /// The fleet kill switch (`EngineV2KVBackendPolicy.killSwitchEnvKey`)
        /// disables paged KV; Super never falls back.
        case pagedDisabled
        /// A policy veto built other storage despite the paged selection; the
        /// builder retired the bridge without serving it.
        case storageNotPaged
        /// The shared budget cannot hold the decode rows; nothing was admitted.
        case decodeRowsRefused
    }

    /// Paged, or a refusal: the load fails rather than serving other storage
    /// or silently changing the measured configuration. The fleet kill switch
    /// would degrade the paged selection to contiguous, so it fails here
    /// before anything is claimed; the builder also refuses a built bridge
    /// whose storage is not paged.
    static func resolve(environment: [String: String]) throws -> EngineV2KVBackendSelection {
        switch environment[key]?.trimmingCharacters(in: .whitespaces) {
        case nil, "paged"?: break
        case "contiguous"?: throw Failure.contiguousUnsupported
        default: throw Failure.invalidBackend
        }
        guard !EngineV2KVBackendPolicy.killSwitchDisabled(environment: environment) else {
            throw Failure.pagedDisabled
        }
        return .paged
    }

    /// The owner-level workspace of `requests` decode rows.
    static func decodeRowsBytes(requests: Int, rowBytes: Int) throws -> Int {
        let (bytes, overflow) = rowBytes.multipliedReportingOverflow(by: requests)
        guard rowBytes >= 0, requests > 0, !overflow else { throw Failure.decodeRowsRefused }
        return bytes
    }

    private static let decodeRowsSuffix = "-nemotron-super-decode-rows"

    /// Budget reservation ID of an owner's decode rows, distinct from request,
    /// lane and bank IDs.
    static func decodeRowsReservationID() -> String { UUID().uuidString + decodeRowsSuffix }

    /// True for a reservation ID made by `decodeRowsReservationID()`.
    static func isDecodeRowsReservationID(_ id: String) -> Bool { id.hasSuffix(decodeRowsSuffix) }
}
