import Foundation

/// Why a resident model is no eviction candidate for a load right now.
enum EvictionExclusionReason: Equatable, Sendable {
    /// Pinned while Autopilot protects pins.
    case autopilotPin
    /// An Autopilot placement hold, until this wall-clock time.
    case autopilotHold(untilMs: Int64)
    /// Accepted requests not yet finished.
    case requestsInFlight(Int)
    /// A local-endpoint request or the startup self-test.
    case localRequest
    case unloading
    /// Retained as the target of an MTP assistant upgrade.
    case assistantUpgrade

    /// The daemon-state vocabulary (`DaemonState.EvictionExclusion.reasons`).
    var code: String {
        switch self {
        case .autopilotPin: "autopilot_pin"
        case .autopilotHold: "autopilot_hold"
        case .requestsInFlight: "requests_in_flight"
        case .localRequest: "local_request"
        case .unloading: "unloading"
        case .assistantUpgrade: "assistant_upgrade"
        }
    }

    /// Work the model is doing, rather than a placement keeping it.
    var isServing: Bool {
        switch self {
        case .requestsInFlight, .localRequest: true
        case .autopilotPin, .autopilotHold, .unloading, .assistantUpgrade: false
        }
    }
}

extension DaemonState.EvictionExclusion {
    /// One model for a refusal or `darkbloom status`: "glm-5.3-flash
    /// (149.5 GB: Autopilot hold until 2026-10-25T15:03:20Z; 1 request in
    /// flight; adopted by Autopilot outside the selected models)".
    public var summary: String {
        var details = reasons.map { reason -> String in
            switch reason {
            case "autopilot_pin": return "pinned by Autopilot"
            case "autopilot_hold":
                return holdExpiresAtMs.map {
                    "Autopilot hold until "
                        + ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double($0) / 1_000))
                } ?? "Autopilot hold"
            case "requests_in_flight":
                let count = requestsInFlight ?? 1
                return count == 1 ? "1 request in flight" : "\(count) requests in flight"
            case "local_request": return "serving a local request"
            case "unloading": return "unloading"
            case "assistant_upgrade": return "MTP assistant upgrade in progress"
            default: return reason
            }
        }
        if adoptedByAutopilot == true { details.append("adopted by Autopilot outside the selected models") }
        return "\(model) (\(String(format: "%.1f", residentGb)) GB: \(details.joined(separator: "; ")))"
    }
}

/// What makes a resident model unreclaimable: the single definition every
/// eviction decision reads (`evictableModelSlots`), and what refusals and
/// the daemon state report.
extension ProviderLoop {
    /// Why each resident model is no eviction candidate now; a model absent
    /// here is evictable.
    func evictionExclusions(now: ContinuousClock.Instant = .now) -> [String: [EvictionExclusionReason]] {
        var inFlight: [String: Int] = [:]
        for model in requestToModel.values { inFlight[model, default: 0] += 1 }
        var exclusions: [String: [EvictionExclusionReason]] = [:]
        for id in modelSlots.keys {
            var reasons: [EvictionExclusionReason] = []
            if autopilotProtectsPins && autopilotPinnedModels.contains(id) { reasons.append(.autopilotPin) }
            if autopilotHoldsModel(id, now: now), let hold = autopilotHolds[id] {
                reasons.append(.autopilotHold(untilMs: hold.untilMs))
            }
            if let count = inFlight[id] { reasons.append(.requestsInFlight(count)) }
            if hasLocalReservation(id) { reasons.append(.localRequest) }
            if modelsUnloading.contains(id) { reasons.append(.unloading) }
            if isMTPUpgradeTargetRetained(id) { reasons.append(.assistantUpgrade) }
            if !reasons.isEmpty { exclusions[id] = reasons }
        }
        return exclusions
    }

    /// Appended to a refused load: every resident model it could not evict,
    /// its resident weights and each reason, and whether Autopilot adopted it
    /// outside the selected models. Empty when every resident was evictable.
    func unevictableResidentsSentence(
        _ exclusions: [String: [EvictionExclusionReason]]? = nil
    ) -> String {
        let records = evictionExclusionRecords(exclusions ?? evictionExclusions())
        guard !records.isEmpty else { return "" }
        return ". Not evictable: " + records.map(\.summary).joined(separator: ", ")
    }

    /// Ends a refusal that found no eviction candidate. Keeps "actively
    /// serving" only when every resident is serving work; a placement or a
    /// transition is named instead.
    func noEvictionCandidateClause() -> String {
        let exclusions = evictionExclusions()
        let serving = exclusions.values.allSatisfy { $0.contains(where: \.isServing) }
        return (serving ? "and all loaded models are actively serving" : "and no loaded model can be evicted")
            + unevictableResidentsSentence(exclusions)
    }

    /// The daemon-state form of `evictionExclusions`, by model.
    func evictionExclusionRecords(
        _ exclusions: [String: [EvictionExclusionReason]]? = nil
    ) -> [DaemonState.EvictionExclusion] {
        let exclusions = exclusions ?? evictionExclusions()
        return exclusions.keys.sorted().map { id in
            let reasons = exclusions[id, default: []]
            var holdExpiresAtMs: Int64?
            var requestsInFlight: Int?
            for reason in reasons {
                switch reason {
                case .autopilotHold(let untilMs): holdExpiresAtMs = untilMs
                case .requestsInFlight(let count): requestsInFlight = count
                default: break
                }
            }
            return DaemonState.EvictionExclusion(
                model: id,
                residentGb: Double(max(0, modelSlots[id]?.sizing.weightsBytes ?? 0)) / 1_073_741_824,
                reasons: reasons.map(\.code), holdExpiresAtMs: holdExpiresAtMs,
                requestsInFlight: requestsInFlight,
                adoptedByAutopilot: autopilotAdoptionIsValid(id) ? true : nil)
        }
    }
}
