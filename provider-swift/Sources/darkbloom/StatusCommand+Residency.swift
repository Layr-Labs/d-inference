import Foundation
import ProviderCore

/// Why the daemon serves a model the saved filter does not name, what
/// Autopilot placed there and until when, and what no load can evict now,
/// all from the daemon's own state. `Enabled model filter` is the saved
/// config, which a running daemon applies only at its next start.
extension Status {
    /// One line naming each served model outside a non-empty saved filter,
    /// with the reason it serves. Older daemons that report no serving
    /// selection explain only adoptions and the live lease.
    static func selectionLines(state: DaemonState, enabledModels: [String]) -> [String] {
        guard !enabledModels.isEmpty else { return [] }
        let adopted = Set(state.autopilot?.adoptedModels ?? [])
        let selection = Set(state.servingSelection ?? [])
        let leased = state.autopilotPhase == "active" || state.autopilotPhase == "transitioning"
        let served = Set(state.warmModels).union(state.advertisedModels ?? []).subtracting(enabledModels)
        let entries = served.sorted().compactMap { id -> String? in
            if adopted.contains(id) { return "\(id) (adopted by an Autopilot operation)" }
            if selection.contains(id) {
                return "\(id) (in the running daemon's selection; the saved filter applies after a restart)"
            }
            return leased ? "\(id) (published under the live Autopilot lease)" : nil
        }
        return entries.isEmpty ? [] : ["Serving outside the enabled model filter: " + entries.joined(separator: ", ")]
    }

    /// Autopilot adoptions and placement holds, each hold with its expiry.
    static func placementLines(state: DaemonState, now: Double) -> [String] {
        guard let autopilot = state.autopilot else { return [] }
        let adopted = Set(autopilot.adoptedModels ?? [])
        let holds = Dictionary((autopilot.heldModels ?? []).map { ($0.modelId, $0.expiresAtMs) },
                               uniquingKeysWith: max)
        let models = adopted.union(holds.keys).sorted()
        guard !models.isEmpty else { return [] }
        let entries = models.map { id in
            var parts: [String] = []
            if adopted.contains(id) { parts.append("adopted outside the selected models") }
            if let expiresAtMs = holds[id] { parts.append("held until \(holdExpiry(expiresAtMs, now: now))") }
            return "\(id) " + parts.joined(separator: ", ")
        }
        return ["Autopilot placements: " + entries.joined(separator: "; ")]
    }

    /// A saved `enabled_models` that differs from the filter the running
    /// selection applies: the start configuration's, or the one the last
    /// committed `switch` saved and applied. The daemon applies a changed
    /// file only at its next start. Older daemons do not report their filter.
    static func pendingSelectionLines(state: DaemonState, enabledModels: [String]) -> [String] {
        guard let applied = state.enabledModelsAtLastSwitch ?? state.enabledModelsAtStart,
              Set(applied) != Set(enabledModels) else { return [] }
        let added = enabledModels.filter { !applied.contains($0) }
        let removed = applied.filter { !enabledModels.contains($0) }
        var changes: [String] = []
        if !added.isEmpty { changes.append("adds \(added.joined(separator: ", "))") }
        if !removed.isEmpty { changes.append("removes \(removed.joined(separator: ", "))") }
        if applied.isEmpty || enabledModels.isEmpty {
            let when = state.enabledModelsAtLastSwitch == nil ? "at start" : "at the last switch"
            changes = ["was [\(applied.joined(separator: ", "))] \(when), is [\(enabledModels.joined(separator: ", "))] now"]
        }
        return ["Configuration change needs a restart to apply: enabled_models "
            + changes.joined(separator: "; ") + ". Run `\(BuildEnvironment.current.cliName) restart`."]
    }

    /// Selected models the daemon keeps trying to load, when the next check
    /// runs and what kept the last one out.
    static func recoveryLines(state: DaemonState, now: Double) -> [String] {
        (state.selectedModelRecovery ?? []).flatMap { entry -> [String] in
            let next = entry.loading == true ? "loading now"
                : entry.nextCheckAt.map { "next check in \(compactDuration(max(0, $0 - now)))" } ?? "check pending"
            var lines = ["Retrying \(entry.model) when memory frees; \(next) "
                + "(waiting \(compactDuration(max(0, now - entry.waitingSince))))"]
            if let blocker = entry.blocker { lines.append("  Last check: \(blocker)") }
            return lines
        }
    }

    /// Resident models no load can evict now, from the daemon's own gate.
    static func evictionExclusionLines(state: DaemonState) -> [String] {
        guard let exclusions = state.evictionExclusions, !exclusions.isEmpty else { return [] }
        return ["Not evictable for a load now: " + exclusions.map(\.summary).joined(separator: ", ")]
    }

    /// "2026-10-25T15:03:20Z (1h0m left)", or "(expired)".
    static func holdExpiry(_ expiresAtMs: Int64, now: Double) -> String {
        let expiry = Double(expiresAtMs) / 1_000
        let left = expiry > now ? "\(compactDuration(expiry - now)) left" : "expired"
        return "\(ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: expiry))) (\(left))"
    }

    /// "45s", "12m", "3h7m".
    static func compactDuration(_ seconds: Double) -> String {
        DurationFormatting.compact(seconds, spaced: false, elideZeroMinutesInHourRange: false)
    }
}
