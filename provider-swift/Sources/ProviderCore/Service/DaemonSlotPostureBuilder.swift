import Foundation
import ProviderCoreFoundation

/// Joins the daemon's LIVE per-slot observations with its own KV-backend
/// config and its last model-load failure into the `DaemonState.slots`
/// inventory the `status`/`doctor` CLI renders.
///
/// The join exists because an explicitly requested paged backend that
/// cannot be built now REFUSES (`EngineV2ProductionError.pagedUnavailable`)
/// instead of degrading, so the failure builds no engine and leaves no live
/// slot behind. Without the synthetic error entry the only remaining
/// evidence would be the model's ABSENCE, and a diagnostic that infers a
/// fault from absence cannot distinguish "paged was refused" from "nobody
/// asked for that model".
///
/// Pure and static so the join rule is testable without a daemon.
///
/// Stays in ProviderCore (not ProviderCoreFoundation) because the join
/// consults `EngineV2KVBackendPolicy`, an inference-runtime type; the wire
/// schema it builds (`DaemonState.SlotPosture`) lives in
/// ProviderCoreFoundation, readable by the app without MLX.
public enum DaemonSlotPostureBuilder {
    /// One slot the daemon currently holds an engine for.
    public struct LiveSlot: Sendable, Equatable {
        public let model: String
        /// `EngineV2Bridge.kvBackendKind.rawValue` — the RESOLVED kind.
        public let kvBackend: String
        /// `EngineV2Bridge.kvBackendFallbackReason` — WHY the resolved kind
        /// differs from the request, nil when it does not (see
        /// `SlotPosture.kvBackendFallbackReason`).
        public let kvBackendFallbackReason: String?
        public let mtpEnabled: Bool
        public let mtpActive: Bool
        public let mtpInactiveReason: String?

        public init(
            model: String,
            kvBackend: String,
            kvBackendFallbackReason: String? = nil,
            mtpEnabled: Bool,
            mtpActive: Bool,
            mtpInactiveReason: String?
        ) {
            self.model = model
            self.kvBackend = kvBackend
            self.kvBackendFallbackReason = kvBackendFallbackReason
            self.mtpEnabled = mtpEnabled
            self.mtpActive = mtpActive
            self.mtpInactiveReason = mtpInactiveReason
        }
    }

    /// How long the synthetic failed-slot entry outlives its failure without
    /// a fresh one. One hour — the daemon's DEFAULT idle-unload horizon
    /// (`idle_timeout_mins`): past it, every REAL slot from the failure's
    /// era has been unloaded and rebuilt on demand anyway, so a failure
    /// older than that horizon describes a previous era of the box, not its
    /// current posture — history for the logs, not a live-looking
    /// `NOT SERVING` row in `status`/`doctor`. Deliberately wedge-scale, not
    /// stale-scale (`KVBackendPosture.staleAfterSeconds` is ~10 s): a
    /// genuinely failed slot must not flap out of `doctor` between two
    /// commands of the same debugging session, and any retry of the load
    /// refreshes `at` (`recordModelLoadError`), keeping a PERSISTENT failure
    /// visible for as long as it actually recurs.
    ///
    /// This constant is the FLOOR; the effective horizon follows the
    /// CONFIGURED idle timeout — see ``failureMaxAge(idleTimeoutMins:)``.
    public static let failureMaxAgeSeconds: Double = 3_600

    /// The effective failed-slot expiry horizon for a box's configured
    /// idle-unload timeout. The whole rationale for expiring by age is "the
    /// idle-unload horizon has passed, so no real slot from the failure's
    /// era survives" — a fixed 3600 s only implements that for the DEFAULT
    /// configuration:
    ///
    ///   * `idle_timeout_mins = 0` (idle unload disabled): nil — there is no
    ///     era boundary, slots live until an operator acts, so the failure
    ///     row only clears via a live slot, config removal, or a fresh
    ///     outcome. Expiring it by age would hide a real failure on exactly
    ///     the box configured to never forget its slots.
    ///   * above 60 min: use it — a box that keeps slots for 4 h keeps its
    ///     failure evidence for 4 h.
    ///   * at or below 60 min: keep the one-hour floor. The wedge-scale
    ///     rationale above still holds — a 5-minute idle timeout must not
    ///     make a genuine failure flap out of `doctor` mid-debugging-session.
    public static func failureMaxAge(idleTimeoutMins: UInt64) -> Double? {
        guard idleTimeoutMins > 0 else { return nil }
        return max(Double(idleTimeoutMins) * 60, failureMaxAgeSeconds)
    }

    /// `live` slots first (sorted by model id), then at most one synthetic
    /// entry for `lastModelLoadError` — and only while that failure is
    /// CURRENT, all three of:
    ///
    ///   * the model has no live slot (a model that failed once and then
    ///     loaded is serving);
    ///   * the model is still in the daemon's desired set (`desiredModels`;
    ///     nil ⇒ unconstrained — an empty `enabled_models` serves anything,
    ///     so membership proves nothing there). An operator who removed the
    ///     model resolved the failure the other way, and a row that outlives
    ///     the config that produced it reports `NOT SERVING` forever for a
    ///     model nobody wants served;
    ///   * the failure is younger than `failureMaxAge` (the caller passes
    ///     ``failureMaxAge(idleTimeoutMins:)`` for its configured idle
    ///     timeout; nil ⇒ no expiry by age — idle unload disabled).
    public static func build(
        live: [LiveSlot],
        requestedGlobal: String,
        requestedByModel: [String: String],
        lastModelLoadError: DaemonState.ModelLoadError?,
        desiredModels: Set<String>? = nil,
        failureMaxAge: Double? = failureMaxAgeSeconds,
        now: Double = Date().timeIntervalSince1970
    ) -> [DaemonState.SlotPosture] {
        func requested(_ modelID: String) -> String {
            EngineV2KVBackendPolicy.parseSelection(
                global: requestedGlobal, byModel: requestedByModel, modelID: modelID
            ).selection.rawValue
        }
        var out = live.sorted { $0.model < $1.model }.map {
            DaemonState.SlotPosture(
                model: $0.model,
                kvBackend: $0.kvBackend,
                kvBackendRequested: requested($0.model),
                kvBackendFallbackReason: $0.kvBackendFallbackReason,
                mtpEnabled: $0.mtpEnabled,
                mtpActive: $0.mtpActive,
                mtpInactiveReason: $0.mtpInactiveReason)
        }
        if let failure = lastModelLoadError,
            !live.contains(where: { $0.model == failure.model }),
            desiredModels.map({ $0.contains(failure.model) }) ?? true,
            failureMaxAge.map({ now - failure.at <= $0 }) ?? true
        {
            out.append(
                DaemonState.SlotPosture(
                    model: failure.model,
                    kvBackend: nil,
                    kvBackendRequested: requested(failure.model),
                    loadError: failure.message))
        }
        return out
    }
}
