import Foundation
import ProviderCore
import Testing

@testable import darkbloom

/// `darkbloom status` and `darkbloom autopilot status` for a consented
/// provider whose filter is Super and Gemma while it serves GLM: they say why
/// GLM serves, what Autopilot placed and until when, what no load can evict,
/// and how old the last load error is. Run as child processes against a
/// temporary provider home (`CLICommandSandbox`).
@Suite("Status residency explanations")
struct StatusResidencyTests {
    static let superID = "nvidia-nemotron-3.5-super"
    static let gemmaID = "gemma-4-26b-qat-4bit"
    static let glmID = "glm-5.3-flash"
    static let refusal = "Insufficient memory (34.8 GB of LOAD room, need 83.6 GB) even after evicting every "
        + "idle model (16.8 GB reclaimable) — refusing without evicting"

    /// The reported daemon state: GLM warm and most recently used, Super
    /// advertised and cold, Autopilot waiting, Super's refusal three hours old.
    static func reportedState(now: Double, adoptedHoldExpiresAtMs: Int64?) throws -> DaemonState {
        var state = try CLICommandSandbox.runningState(
            now: now, currentModel: glmID, warmModels: [gemmaID, glmID],
            advertisedModels: [gemmaID, glmID, superID],
            stats: .init(requestsServed: 2_959, tokensGenerated: 1_000_000, usageGaps: 0),
            capacity: .init(totalMemoryGb: 256, gpuMemoryActiveGb: 188, loadUsableGb: 42.3,
                            loadHeadroomGb: 6.5, freeForLoadGb: 223.9),
            lastModelLoadError: .init(model: superID, message: refusal, at: now - 3 * 3_600))
        state.autopilotPhase = "waiting"
        state.modelSwitch = ProviderModelSwitchStatus()
        var autopilot = ModelAutopilotSnapshot(enabled: true, consentEnabled: true)
        autopilot.revision = "revision"
        autopilot.selectedModels = [gemmaID, glmID, superID]
        if let expiresAtMs = adoptedHoldExpiresAtMs {
            autopilot.adoptedModels = [glmID]
            autopilot.heldModels = [ModelAutopilotHold(modelId: glmID, expiresAtMs: expiresAtMs)]
            autopilot.lastCommandId = "op_0123456789abcdef0123456789abcdef"
            autopilot.lastCommandStatus = .succeeded
            state.autopilotOperation = .init(reason: "coordinator placement", target: glmID,
                                             releasing: [superID], elapsedMs: 41_200)
        }
        state.autopilot = autopilot
        return state
    }

    @Test("an admin operation's adopted, held GLM is explained in status and autopilot status")
    func adoptedHeldModel() async throws {
        let result = try await #require(processExitsWith: .success, observing: [\.standardOutputContent]) {
            let sandbox = try CLICommandSandbox.enter(enabledModels: [Self.superID, Self.gemmaID], autoRestart: false)
            defer { sandbox.remove() }
            let now = Date().timeIntervalSince1970
            let expiresAtMs = Int64((now + 3_630) * 1_000)
            print("== EXPIRY \(ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(expiresAtMs) / 1_000)))")
            try sandbox.writeState(Self.reportedState(now: now, adoptedHoldExpiresAtMs: expiresAtMs), adding: [
                "serving_selection": [Self.gemmaID, Self.superID],
                "eviction_exclusions": [[
                    "model": Self.glmID, "resident_gb": 149.5, "reasons": ["autopilot_hold"],
                    "hold_expires_at_ms": expiresAtMs, "adopted_by_autopilot": true,
                ]],
            ])
            print("== STATUS")
            try await runCLICommand(Status.self, ["status", "--config", sandbox.config.path])
            print("== AUTOPILOT")
            try await runCLICommand(Autopilot.Status.self, ["autopilot", "status", "--config", sandbox.config.path])
            print("== END")
        }
        let output = decodedText(result.standardOutputContent)
        let expiry = try #require(output.components(separatedBy: "== EXPIRY ").dropFirst().first?
            .components(separatedBy: "\n").first)
        let status = try #require(outputSection(output, from: "== STATUS", to: "== AUTOPILOT"))
        #expect(status.contains("\nEnabled model filter: \(Self.superID), \(Self.gemmaID)\n"))
        #expect(status.contains("\nAutopilot - Experimental: waiting (not activated; no current coordinator control)\n"))
        #expect(status.contains("\nWarm models: "))
        #expect(status.contains("\nServing outside the enabled model filter: \(Self.glmID) (adopted by an Autopilot operation)\n"),
                "\(status)")
        #expect(status.contains("\nAutopilot placements: \(Self.glmID) adopted outside the selected models, held until \(expiry) ("),
                "\(status)")
        #expect(status.contains("\nNot evictable for a load now: \(Self.glmID) (149.5 GB: Autopilot hold until \(expiry); "
            + "adopted by Autopilot outside the selected models)\n"), "\(status)")
        #expect(status.contains("\nLast model-load error: \(Self.superID): \(Self.refusal)\n  Recorded 3h0m ago\n"),
                "\(status)")

        let autopilot = try #require(outputSection(output, from: "== AUTOPILOT", to: "== END"))
        #expect(autopilot.contains("\n  Last transition: succeeded\n"))
        #expect(autopilot.contains("\n  Target: \(Self.glmID)\n"))
        #expect(autopilot.contains("\n  Release: \(Self.superID)\n"))
        #expect(autopilot.contains("\n  Adopted (serving outside the selection): \(Self.glmID)\n"), "\(autopilot)")
        #expect(autopilot.contains("\n  Held: \(Self.glmID) until \(expiry) ("), "\(autopilot)")
    }

    @Test("a model in the running daemon's selection is explained as such")
    func startSelectionOutsideTheFilter() async throws {
        let result = try await #require(processExitsWith: .success, observing: [\.standardOutputContent]) {
            let sandbox = try CLICommandSandbox.enter(enabledModels: [Self.superID, Self.gemmaID], autoRestart: false)
            defer { sandbox.remove() }
            let now = Date().timeIntervalSince1970
            try sandbox.writeState(Self.reportedState(now: now, adoptedHoldExpiresAtMs: nil), adding: [
                "serving_selection": [Self.gemmaID, Self.glmID, Self.superID],
                "eviction_exclusions": [[String: Any]](),
            ])
            print("== STATUS")
            try await runCLICommand(Status.self, ["status", "--config", sandbox.config.path])
            print("== AUTOPILOT")
            try await runCLICommand(Autopilot.Status.self, ["autopilot", "status", "--config", sandbox.config.path])
            print("== END")
        }
        let output = decodedText(result.standardOutputContent)
        let status = try #require(outputSection(output, from: "== STATUS", to: "== AUTOPILOT"))
        #expect(status.contains("\nServing outside the enabled model filter: \(Self.glmID) "
            + "(in the running daemon's selection; the saved filter applies after a restart)\n"), "\(status)")
        #expect(!status.contains("Autopilot placements"), "\(status)")
        #expect(!status.contains("Not evictable"), "\(status)")
        let autopilot = try #require(outputSection(output, from: "== AUTOPILOT", to: "== END"))
        #expect(!autopilot.contains("Adopted"))
        #expect(!autopilot.contains("Target:"))
    }
}

extension CLICommandSandbox {
    /// Writes `state` as the daemon does, plus `extra` top-level keys.
    func writeState(_ state: DaemonState, adding extra: [String: Any]) throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        var object = try #require(JSONSerialization.jsonObject(with: encoder.encode(state)) as? [String: Any])
        object.merge(extra) { _, new in new }
        try JSONSerialization.data(withJSONObject: object).write(to: stateFile, options: .atomic)
    }
}
