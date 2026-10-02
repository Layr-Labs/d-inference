import ArgumentParser
import Foundation
import ProviderCore

extension Autopilot {
    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show configured consent and live Autopilot state.")
        @OptionGroup var configOptions: ConfigOptions
        @Flag(help: "Emit JSON.") var json = false
        mutating func run() async throws {
            let runtime = try loadRuntimeSnapshot(configOptions: configOptions)
            let settings = runtime.config.backend.modelAutopilot
            let live = DaemonStateFile.read()
            let fresh = live.map { daemonProcessAlive(pid: $0.pid) && Self.snapshotIsFresh($0,
                heartbeatIntervalSecs: runtime.config.coordinator.heartbeatIntervalSecs,
                now: Date().timeIntervalSince1970) } ?? false
            if json {
                try printJSON(AutopilotStatusOutput(configured: settings, live: fresh ? live?.autopilot : nil,
                    phase: fresh ? live?.autopilotPhase : nil, operation: fresh ? live?.autopilotOperation : nil))
                return
            }
            print("Autopilot - Experimental: \(settings.hasConsent ? "enrolled" : "off")")
            print("  Live state: \(Self.phaseDescription(fresh ? live?.autopilotPhase : nil))")
            if fresh && live?.autopilot?.revision != settings.revision { print("  Configuration change waiting to apply") }
            print("  Selected: \(settings.selectedModels.joined(separator: ", "))")
            print("  Pinned: \(settings.pinnedModels.isEmpty ? "none" : settings.pinnedModels.joined(separator: ", "))")
            if fresh, let state = live?.autopilot {
                print("  Loaded in memory: \(state.residentModels.map(\.modelId).joined(separator: ", "))")
                if let command = state.activeCommandId { print("  Transition: \(command)") }
                if let result = state.lastCommandStatus { print("  Last transition: \(result.rawValue)") }
            }
            if fresh, let operation = live?.autopilotOperation {
                print("  Reason: \(operation.reason.replacingOccurrences(of: "_", with: " "))")
                if let target = operation.target { print("  Target: \(target)") }
                if !operation.releasing.isEmpty { print("  Release: \(operation.releasing.joined(separator: ", "))") }
                if let elapsed = operation.elapsedMs { print("  Last transition: \(String(format: "%.1f", Double(elapsed)/1000)) s") }
            }
            print("  Pause/resume: darkbloom autopilot pause | resume")
            print("  Change selection: darkbloom autopilot models")
        }

        static func snapshotIsFresh(_ state: DaemonState, heartbeatIntervalSecs: UInt64, now: Double) -> Bool {
            !state.isStale(now: now, maxAge: KVBackendPosture.staleAfterSeconds(
                heartbeatIntervalSecs: heartbeatIntervalSecs))
        }

        static func phaseDescription(_ phase: String?) -> String {
            guard let phase else { return "daemon not reporting" }
            switch phase {
            case "shadow": return "shadow (not activated; no automatic model changes)"
            case "waiting": return "waiting (not activated; no current coordinator control)"
            default: return phase
            }
        }
    }

}

private struct AutopilotStatusOutput: Encodable {
    let configured: ModelAutopilotSettings
    let live: ModelAutopilotSnapshot?
    let phase: String?
    let operation: DaemonState.AutopilotOperation?
}
