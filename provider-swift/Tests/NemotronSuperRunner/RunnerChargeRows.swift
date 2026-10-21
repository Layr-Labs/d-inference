import MLXLMCommon
@testable import ProviderCore

enum RunnerChargeKind: String, Sendable {
    case load, mediaIngress = "media_ingress", media, kv, ballast
    /// The owner's prefill activation lane (NemotronSuperLocalPrefill).
    case prefillLane = "prefill_lane"
    /// The owner's resident checkpoint bank budget (NemotronSuperLocalPrefixCache).
    case prefixBank = "prefix_bank"
}

struct RunnerChargeRow: Sendable {
    let id: String
    let kind: RunnerChargeKind
    let bytes: UInt64
}

extension GlobalKVCacheBudget {
    /// LOAD rows come from the pending-load table, request rows from the
    /// read-only reservation snapshot; both are read inside the budget's
    /// isolation. Kinds follow the reservation-ID suffixes
    /// NemotronSuperLocalImageBinding, the owner's prefill lane and its
    /// checkpoint bank use; every other request ID is a bridge
    /// (KV) reservation in this single-owner runner.
    func runnerChargeRows(ballastID: String) -> [RunnerChargeRow] {
        var rows = pendingLoads.values.map {
            RunnerChargeRow(id: $0.requestID, kind: .load, bytes: $0.state.chargedBytes)
        }
        for (id, bytes) in reservationBytesSnapshot() {
            let kind: RunnerChargeKind =
                id == ballastID ? .ballast
                : id.hasSuffix("-ingress") ? .mediaIngress
                : id.hasSuffix("-media") ? .media
                : NemotronSuperLocalPrefill.isLaneReservationID(id) ? .prefillLane
                : NemotronSuperLocalPrefixCache.isBankReservationID(id) ? .prefixBank : .kv
            rows.append(RunnerChargeRow(id: id, kind: kind, bytes: bytes))
        }
        return rows.sorted { $0.id < $1.id }
    }
}
