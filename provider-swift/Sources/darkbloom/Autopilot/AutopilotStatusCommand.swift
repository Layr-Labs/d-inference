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
            let downloads = runtime.config.backend.autopilotDownloads ?? .init()
            let usage = AutopilotDownloadLedger.read(from: AutopilotDownloadLedger.url(
                configDirectory: runtime.configPath.deletingLastPathComponent()))
                .usage { ModelScanner.resolveLocalPath(modelID: $0) != nil }
            if json {
                try printJSON(AutopilotStatusOutput(configured: settings, live: fresh ? live?.autopilot : nil,
                    phase: fresh ? live?.autopilotPhase : nil, operation: fresh ? live?.autopilotOperation : nil,
                    downloads: downloads, downloadUsage: .init(usedBytes: usage.bytes, usedModels: usage.models)))
                return
            }
            print("Autopilot - Experimental: \(settings.hasConsent ? "enrolled" : "off")")
            print("  Live state: \(Self.phaseDescription(fresh ? live?.autopilotPhase : nil))")
            if fresh && live?.autopilot?.revision != settings.revision { print("  Configuration change waiting to apply") }
            print("  Selected: \(settings.selectedModels.joined(separator: ", "))")
            // The running provider adds every verified downloaded catalog build.
            if fresh, let set = live?.autopilot?.selectedModels {
                let downloaded = set.filter { !settings.selectedModels.contains($0) }
                if !downloaded.isEmpty { print("  Also downloaded: \(downloaded.joined(separator: ", "))") }
            }
            print("  Pinned: \(settings.pinnedModels.isEmpty ? "none" : settings.pinnedModels.joined(separator: ", "))")
            // On by default, but only an enrolled Mac downloads anything.
            let downloadState = !downloads.enabled ? "off"
                : settings.hasConsent ? "on. \(describeAutopilotDownloadLimits(downloads))" : "on once enrolled"
            print("  Downloads: \(downloadState)")
            if downloads.enabled || usage.models > 0 {
                print("  Downloaded by Autopilot: \(usage.models) model(s), \(String(format: "%.1f", Double(usage.bytes) / 1_073_741_824)) GiB")
            }
            if fresh, let storage = live?.autopilot?.downloadStorage {
                print("  Free disk: \(String(format: "%.1f", Double(storage.diskFreeBytes) / 1_073_741_824)) GiB")
            }
            if fresh, let state = live?.autopilot {
                print("  Loaded in memory: \(state.residentModels.map(\.modelId).joined(separator: ", "))")
                if let adopted = state.adoptedModels, !adopted.isEmpty {
                    print("  Adopted (serving outside the selection): \(adopted.joined(separator: ", "))")
                }
                let now = Date().timeIntervalSince1970
                for hold in state.heldModels ?? [] {
                    print("  Held: \(hold.modelId) until \(darkbloom.Status.holdExpiry(hold.expiresAtMs, now: now))")
                }
                if let command = state.activeCommandId { print("  Transition: \(command)") }
                if let result = state.lastCommandStatus { print("  Last transition: \(result.rawValue)") }
            }
            if fresh, let operation = live?.autopilotOperation {
                print("  Reason: \(operation.reason.replacingOccurrences(of: "_", with: " "))")
                if let target = operation.target { print("  Target: \(target)") }
                if !operation.releasing.isEmpty { print("  Release: \(operation.releasing.joined(separator: ", "))") }
                if let elapsed = operation.elapsedMs { print("  Last transition: \(String(format: "%.1f", Double(elapsed)/1000)) s") }
            }
            print("  Pause/resume: \(BuildEnvironment.current.cliName) autopilot pause | resume")
            print("  Change selection: \(BuildEnvironment.current.cliName) autopilot models")
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
            case "waiting_inventory": return "waiting for inventory refresh (not activated; run \(BuildEnvironment.current.cliName) autopilot models)"
            default: return phase
            }
        }
    }

}

private struct AutopilotStatusOutput: Encodable {
    struct DownloadUsage: Encodable {
        let usedBytes: Int64
        let usedModels: Int
        enum CodingKeys: String, CodingKey { case usedBytes = "used_bytes", usedModels = "used_models" }
    }
    let configured: ModelAutopilotSettings
    let live: ModelAutopilotSnapshot?
    let phase: String?
    let operation: DaemonState.AutopilotOperation?
    let downloads: AutopilotDownloadSettings
    let downloadUsage: DownloadUsage
    enum CodingKeys: String, CodingKey {
        case configured, live, phase, operation, downloads, downloadUsage = "download_usage"
    }
}
