// Copyright © 2026 Eigen Labs.

import Foundation

/// Attention KV storage of the unpublished Super owner. Contiguous unless the
/// runtime policy selects the segmented native paged backend (BF16 layer
/// types observed from the loaded model), as the managed slot's serving
/// policy does by default (`NemotronSuperServingPolicy.loadPlan`). Paged
/// storage is charged to the shared budget by the engine's process-memory
/// owner as segments and recurrent rows materialize, and the bridge then
/// reserves no request bytes of its own; the owner therefore reserves every
/// request's decode-row workspace itself, like the prefill lane, from before
/// the first request until native retirement.
enum NemotronSuperLocalKVBackend {
    /// Runtime-policy key: `contiguous` (builder default) or `paged`.
    static let key = "DARKBLOOM_NEMOTRON_SUPER_KV_BACKEND"

    enum Failure: Error, Equatable {
        /// The key is neither `contiguous` nor `paged`.
        case invalidBackend
        /// The shared budget cannot hold the decode rows; nothing was admitted.
        case decodeRowsRefused
    }

    /// A malformed value fails the load rather than silently changing the
    /// measured configuration. A paged selection never degrades to
    /// contiguous: paged construction failures fail the load.
    static func resolve(environment: [String: String]) throws -> EngineV2KVBackendSelection {
        guard let raw = environment[key]?.trimmingCharacters(in: .whitespaces) else {
            return .contiguous
        }
        switch raw {
        case "contiguous": return .contiguous
        case "paged": return .paged
        default: throw Failure.invalidBackend
        }
    }

    /// The owner-level workspace of `requests` decode rows; zero when the
    /// bridge reserves it with each request (contiguous storage).
    static func decodeRowsBytes(selection: EngineV2KVBackendSelection, requests: Int, rowBytes: Int)
        throws -> Int {
        guard selection == .paged else { return 0 }
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
