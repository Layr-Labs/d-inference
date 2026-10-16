import MLXLMCommon
@testable import ProviderCore

// The only place the runner reads private provider state. Each read runs inside
// the owning actor's isolation, so it is race-free, and it never mutates. The
// runner report requests two internal accessors that make this file obsolete:
// a per-reservation byte table on GlobalKVCacheBudget and an image-hook accessor
// on NemotronSuperLocalLoad. Until then, a missing field degrades diagnostics
// (bytes become null / the image route is disabled) instead of guessing.

enum RunnerChargeKind: String, Sendable {
    case load, mediaIngress = "media_ingress", media, kv, ballast
}

struct RunnerChargeRow: Sendable {
    let id: String
    let kind: RunnerChargeKind
    /// nil when the private reservation table could not be reflected.
    let bytes: UInt64?
}

private func reflectedChild<T>(_ subject: Any, _ label: String) -> T? {
    Mirror(reflecting: subject).children.first { $0.label == label }?.value as? T
}

extension GlobalKVCacheBudget {
    /// LOAD rows come from the internal pending-load table; request rows from
    /// the private reservation table. Kinds follow the reservation-ID suffixes
    /// NemotronSuperLocalImageBinding uses; every other request ID is a bridge
    /// (KV) reservation in this single-owner runner.
    func runnerChargeRows(ballastID: String) -> [RunnerChargeRow] {
        var rows = pendingLoads.values.map {
            RunnerChargeRow(id: $0.requestID, kind: .load, bytes: $0.state.chargedBytes)
        }
        let loadIDs = Set(pendingLoadIDs.keys)
        let reflected: [String: Reservation]? = reflectedChild(self, "reservations")
        let ids = reflected.map { Array($0.keys) }
            ?? reservationIDsForTesting().filter { !loadIDs.contains($0) }
        for id in ids {
            let kind: RunnerChargeKind =
                id == ballastID ? .ballast
                : id.hasSuffix("-ingress") ? .mediaIngress
                : id.hasSuffix("-media") ? .media : .kv
            rows.append(RunnerChargeRow(id: id, kind: kind, bytes: reflected?[id]?.bytes))
        }
        return rows.sorted { $0.id < $1.id }
    }
}

extension NemotronSuperLocalLoad {
    /// The exact owner the transaction installed, for the opt-in image hook.
    func runnerOwner() -> NemotronSuperLocalBridgeBuilder.Owner? {
        guard phase == .ready else { return nil }
        return reflectedChild(self, "owner")
    }

    func runnerResidency() -> NemotronSuperResidency? { reflectedChild(self, "residency") }
}
