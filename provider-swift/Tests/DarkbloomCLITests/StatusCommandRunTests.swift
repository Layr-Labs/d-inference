import Foundation
import ProviderCore
import Testing

@testable import darkbloom

/// `darkbloom status` end to end against a temporary provider home, in a
/// child process (`CLICommandSandbox`). The config turns `auto_restart` off,
/// so the command never asks launchd whether the watchdog is loaded.
@Suite("Status command run")
struct StatusCommandRunTests {

    @Test("status prints the config summary and each daemon state: none, exited, trusted and authorized")
    func daemonStates() async throws {
        let result = try await #require(
            processExitsWith: .success, observing: [\.standardOutputContent]
        ) {
            let sandbox = try CLICommandSandbox.enter(autoRestart: false)
            defer { sandbox.remove() }
            try sandbox.makeModel("acme/Alpha-4bit")
            let arguments = ["status", "--config", sandbox.config.path]

            print("== NONE")
            try await runCLICommand(Status.self, arguments)

            var now = Date().timeIntervalSince1970
            var exited = try CLICommandSandbox.runningState(now: now)
            exited.pid = Int32.max
            sandbox.writeState(exited)
            print("== EXITED")
            try await runCLICommand(Status.self, arguments)

            now = Date().timeIntervalSince1970
            KVBackendGuardStore.write(
                KVBackendGuard(trippedAt: now - 120, providerVersion: ProviderCore.version, crashCount: 3))
            sandbox.writeState(try CLICommandSandbox.runningState(
                now: now,
                trust: .init(trustLevel: "hardware", status: "online", reason: "verified", receivedAt: now),
                currentModel: "acme/Warm-4bit",
                warmModels: ["acme/Warm-4bit"],
                advertisedModels: ["acme/Alpha-4bit", "acme/Warm-4bit"],
                stats: .init(requestsServed: 12, tokensGenerated: 3_400, usageGaps: 0),
                capacity: .init(
                    totalMemoryGb: 128, gpuMemoryActiveGb: 4, loadUsableGb: 100, loadHeadroomGb: 2,
                    freeForLoadGb: 90),
                lastModelLoadError: .init(model: "acme/Alpha-4bit", message: "weights unreadable", at: now - 30)))
            print("== TRUSTED")
            try await runCLICommand(Status.self, arguments)

            try FileManager.default.removeItem(at: sandbox.guardFile)
            now = Date().timeIntervalSince1970
            sandbox.writeState(try CLICommandSandbox.runningState(
                now: now,
                trust: .init(
                    trustLevel: "self_signed", status: "online", reason: "app attest", receivedAt: now,
                    authorization: CLICommandSandbox.appAttestAuthorization(now: now))))
            print("== AUTHORIZED")
            try await runCLICommand(Status.self, arguments)
            print("== END")
        }
        let output = decodedText(result.standardOutputContent)

        let none = try #require(ReportCommandRunTests.section(output, from: "== NONE", to: "== EXITED"))
        #expect(none.hasPrefix("darkbloom \(ProviderCore.version)\nProvider: cli-sandbox\nConfig: "))
        #expect(none.contains("\nCoordinator: https://coordinator.invalid\n"))
        #expect(none.contains("\nAuto-restart: off (auto_restart = false)\n"))
        #expect(none.contains("\nLocal boot checks: "))
        #expect(none.contains("\nSchedule: always available\n"))
        #expect(none.contains("\nEnabled model filter: none\n"))
        #expect(none.contains("\nServing concurrency: "))
        #expect(none.hasSuffix("\nDaemon: not running (run `darkbloom start`)\n"))

        let exited = try #require(ReportCommandRunTests.section(output, from: "== EXITED", to: "== TRUSTED"))
        #expect(exited.hasSuffix("\nDaemon: not running (stale state file)\n"))

        let trusted = try #require(ReportCommandRunTests.section(output, from: "== TRUSTED", to: "== AUTHORIZED"))
        #expect(trusted.contains("\nDaemon: running (pid "))
        #expect(trusted.contains(", up 1h1m)\n"))
        #expect(trusted.contains("\nTrust: hardware / online\n  → "))
        #expect(trusted.contains("\nWarm models: "))
        #expect(trusted.contains("\nNot loaded (loads on request): acme/Alpha-4bit\n"))
        #expect(trusted.contains("\nRequests served: 12  |  tokens: 3400\n"))
        #expect(trusted.contains("\nLast model-load error: acme/Alpha-4bit: weights unreadable\n"))
        #expect(trusted.contains("\nKV-backend guard: ACTIVE — `.auto` serves contiguous on this box "))

        let authorized = try #require(ReportCommandRunTests.section(output, from: "== AUTHORIZED", to: "== END"))
        #expect(authorized.contains("\nAuthorization: App Attest authorizes this connection. "))
        #expect(authorized.contains("\nMachine ID: machine-1\n"))
        #expect(!authorized.contains("\nTrust: "))
        #expect(!authorized.contains("KV-backend guard"))
    }
}
