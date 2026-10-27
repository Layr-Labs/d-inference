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

        let none = try #require(outputSection(output, from: "== NONE", to: "== EXITED"))
        #expect(none.hasPrefix("darkbloom \(ProviderCore.version)\nProvider: cli-sandbox\nConfig: "))
        #expect(none.contains("\nCoordinator: https://coordinator.invalid\n"))
        #expect(none.contains("\nAuto-restart: off (auto_restart = false)\n"))
        #expect(none.contains("\nLocal boot checks: "))
        #expect(none.contains("\nSchedule: always available\n"))
        #expect(none.contains("\nEnabled model filter: none\n"))
        #expect(none.contains("\nServing concurrency: "))
        #expect(none.hasSuffix("\nDaemon: not running (run `darkbloom start`)\n"))

        let exited = try #require(outputSection(output, from: "== EXITED", to: "== TRUSTED"))
        #expect(exited.hasSuffix("\nDaemon: not running (stale state file)\n"))

        let trusted = try #require(outputSection(output, from: "== TRUSTED", to: "== AUTHORIZED"))
        #expect(trusted.contains("\nDaemon: running (pid "))
        #expect(trusted.contains(", up 1h1m)\n"))
        #expect(trusted.contains("\nTrust: hardware / online\n  → "))
        #expect(trusted.contains("\nWarm models: "))
        #expect(trusted.contains("\nNot loaded (loads on request): acme/Alpha-4bit\n"))
        #expect(trusted.contains("\nRequests served since the daemon started (1h1m ago): 12  |  output tokens: 3400\n"
            + "  Paid jobs are listed under Earnings in the console; requests to your own machine are free.\n"))
        #expect(!trusted.contains("ended early"))
        #expect(trusted.contains("\nLast model-load error: acme/Alpha-4bit: weights unreadable\n"))
        #expect(trusted.contains("\nKV-backend guard: ACTIVE — packed autoregressive `.auto` (`balanced`/`k8v4`/`k8v8`) "))
        #expect(trusted.contains("requires paged and is refused while guarded"))
        #expect(trusted.contains("--clear-backend-guard` to permit a paged retry"))
        #expect(trusted.contains("default live `native` precision permits contiguous `.auto`"))
        #expect(!trusted.contains("serves contiguous on this box"))

        let authorized = try #require(outputSection(output, from: "== AUTHORIZED", to: "== END"))
        #expect(authorized.contains("\nAuthorization: App Attest authorizes this connection. "))
        #expect(authorized.contains("\nMachine ID: machine-1\n"))
        #expect(!authorized.contains("\nTrust: "))
        #expect(!authorized.contains("KV-backend guard"))
        #expect(!authorized.contains("\nNot serving: "))
    }

    /// `Requests served` is this daemon session's own count, not the
    /// coordinator's paid jobs: it resets with the daemon, counts output
    /// tokens only, and includes requests that ended early on a cancel, which
    /// the coordinator may not pay for. The early-end count is patched into
    /// the state file under the key the daemon writes.
    @Test("status scopes requests served to the daemon session and separates those that ended early")
    func servedRequestsAreScopedToTheSession() async throws {
        let result = try await #require(
            processExitsWith: .success, observing: [\.standardOutputContent]
        ) {
            let sandbox = try CLICommandSandbox.enter(autoRestart: false)
            defer { sandbox.remove() }
            let arguments = ["status", "--config", sandbox.config.path]

            sandbox.writeState(try CLICommandSandbox.runningState(now: Date().timeIntervalSince1970))
            print("== IDLE")
            try await runCLICommand(Status.self, arguments)

            sandbox.writeState(try CLICommandSandbox.runningState(
                now: Date().timeIntervalSince1970,
                stats: .init(requestsServed: 78, tokensGenerated: 84_000, usageGaps: 0)))
            var state = try #require(
                try JSONSerialization.jsonObject(with: Data(contentsOf: sandbox.stateFile)) as? [String: Any])
            var stats = try #require(state["stats"] as? [String: Any])
            stats["cancellations_partial_complete"] = 5
            state["stats"] = stats
            try JSONSerialization.data(withJSONObject: state).write(to: sandbox.stateFile)
            print("== SERVED")
            try await runCLICommand(Status.self, arguments)
            print("== END")
        }
        let output = decodedText(result.standardOutputContent)

        let idle = try #require(outputSection(output, from: "== IDLE", to: "== SERVED"))
        #expect(idle.contains("\nRequests served since the daemon started (1h1m ago): 0  |  output tokens: 0\n"))
        #expect(!idle.contains("Earnings"))

        let served = try #require(outputSection(output, from: "== SERVED", to: "== END"))
        #expect(served.contains("\nRequests served since the daemon started (1h1m ago): 78  |  output tokens: 84000\n"
            + "  5 of them ended early on a coordinator cancel or a dropped connection and may be unpaid.\n"
            + "  Paid jobs are listed under Earnings in the console; requests to your own machine are free.\n"))
    }

    /// An interrupted or timed-out `darkbloom restart` leaves the old process
    /// alive but refusing work, so the coordinator shows it offline. Status
    /// must say so on the line right after "Daemon: running".
    @Test("status reports a live provider whose drain did not finish as not serving")
    func unfinishedDrainIsNotServing() async throws {
        let result = try await #require(
            processExitsWith: .success, observing: [\.standardOutputContent]
        ) {
            let sandbox = try CLICommandSandbox.enter(autoRestart: false)
            defer { sandbox.remove() }
            var state = try CLICommandSandbox.runningState(now: Date().timeIntervalSince1970)
            state.lifecycle = ProviderDrainStatus(
                requestID: "restart-1", outcome: .timedOut, remaining: 0, coordinatorAcknowledged: true)
            sandbox.writeState(state)
            try await runCLICommand(Status.self, ["status", "--config", sandbox.config.path])
        }
        let lines = decodedText(result.standardOutputContent).components(separatedBy: "\n")

        let daemon = try #require(lines.firstIndex { $0.hasPrefix("Daemon: running (pid ") })
        #expect(lines.dropFirst(daemon + 1).first == Status.lifecycleDrainLine(
            ProviderDrainStatus(outcome: .timedOut, remaining: 0)))
    }

    /// A connected provider the coordinator does not route to looked healthy
    /// in `status` ("Trust: awaiting coordinator status", or a stale trust
    /// line) while earning nothing. The Traffic line says why.
    @Test("status says why a connected provider receives no coordinator work")
    func trafficVerdict() async throws {
        let result = try await #require(
            processExitsWith: .success, observing: [\.standardOutputContent]
        ) {
            let sandbox = try CLICommandSandbox.enter(autoRestart: false)
            defer { sandbox.remove() }
            let arguments = ["status", "--config", sandbox.config.path]
            var now = Date().timeIntervalSince1970
            var state = try CLICommandSandbox.runningState(now: now)
            state.coordinatorConnection = .init(connected: true, since: now - 1_200, connections: 2)
            sandbox.writeState(state)
            print("== NO STATUS")
            try await runCLICommand(Status.self, arguments)

            now = Date().timeIntervalSince1970
            state = try CLICommandSandbox.runningState(
                now: now,
                trust: .init(
                    trustLevel: "self_signed", status: "online", reason: "Provider authorization updated",
                    receivedAt: now - 30,
                    authorization: ProviderAuthorizationStatus(
                        appAttestAvailable: true, path: "none", reason: "app_attest_keychain_error",
                        sessionID: "session", machineID: "")))
            state.coordinatorConnection = .init(connected: true, since: now - 1_200, connections: 1)
            sandbox.writeState(state)
            print("== KEYCHAIN")
            try await runCLICommand(Status.self, arguments)

            now = Date().timeIntervalSince1970
            state = try CLICommandSandbox.runningState(
                now: now,
                trust: .init(
                    trustLevel: "self_signed", status: "online", reason: "app attest", receivedAt: now,
                    authorization: CLICommandSandbox.appAttestAuthorization(now: now)))
            state.coordinatorConnection = .init(connected: true, since: now - 1_200, connections: 1)
            sandbox.writeState(state)
            print("== AUTHORIZED")
            try await runCLICommand(Status.self, arguments)
            print("== END")
        }
        let output = decodedText(result.standardOutputContent)

        let missing = try #require(outputSection(output, from: "== NO STATUS", to: "== KEYCHAIN"))
        #expect(missing.contains("\nTrust: awaiting coordinator status\nTraffic: NOT receiving coordinator work: "
            + "connected for 20m, but the coordinator has not confirmed this connection\n  → fix: run `darkbloom restart`"))

        let keychain = try #require(outputSection(output, from: "== KEYCHAIN", to: "== AUTHORIZED"))
        #expect(keychain.contains("\nTraffic: NOT receiving coordinator work: the coordinator is not routing work here: "
            + "the login keychain refused this Mac's App Attest key record (it is usually locked)\n"
            + "  → fix: log in at this Mac's console to unlock the login keychain"))

        let authorized = try #require(outputSection(output, from: "== AUTHORIZED", to: "== END"))
        #expect(authorized.contains("\nTraffic: eligible for coordinator work (App Attest authorized until "))
        #expect(!authorized.contains("NOT receiving"))
    }

    /// An add-on hold keeps the connection, still authorized, but takes the
    /// Mac out of routing on purpose. Its `Not serving:` line says so; no
    /// Traffic line contradicts it.
    @Test("status shows a held provider's hold line and no traffic verdict")
    func heldProviderHasNoTrafficVerdict() async throws {
        let result = try await #require(
            processExitsWith: .success, observing: [\.standardOutputContent]
        ) {
            let sandbox = try CLICommandSandbox.enter(autoRestart: false)
            defer { sandbox.remove() }
            let now = Date().timeIntervalSince1970
            var state = try CLICommandSandbox.runningState(
                now: now,
                trust: .init(
                    trustLevel: "self_signed", status: "online", reason: "app attest", receivedAt: now,
                    authorization: CLICommandSandbox.appAttestAuthorization(now: now)))
            state.coordinatorConnection = .init(connected: true, since: now - 1_200, connections: 1)
            state.addonHold = AddonHoldSnapshot(holds: [AddonHoldView(
                holdId: "hold", addon: "io.darkbloom.sandbox", state: "held",
                sinceMs: Int64((now - 300) * 1_000), leaseExpiresAtMs: Int64((now + 60) * 1_000), vmBytes: 8 << 30)])
            sandbox.writeState(state)
            try await runCLICommand(Status.self, ["status", "--config", sandbox.config.path])
        }
        let output = decodedText(result.standardOutputContent)
        #expect(output.contains("\nNot serving: held by add-on io.darkbloom.sandbox: held since "))
        #expect(!output.contains("Traffic:"))
    }

    /// A renewal received 15 s ago with an unexpired lease must not turn
    /// status into legacy trust or offer removal without fresh readiness.
    @Test("status keeps reporting App Attest while the lease is unexpired and a renewal is late")
    func lateLeaseRenewalStillAuthorizes() async throws {
        let result = try await #require(
            processExitsWith: .success, observing: [\.standardOutputContent]
        ) {
            let sandbox = try CLICommandSandbox.enter(autoRestart: false)
            defer { sandbox.remove() }
            let now = Date().timeIntervalSince1970
            var authorization = CLICommandSandbox.appAttestAuthorization(now: now, removalReady: true)
            authorization.expiresAt = now + 15
            sandbox.writeState(try CLICommandSandbox.runningState(
                now: now,
                trust: .init(trustLevel: "self_signed", status: "online", reason: "Provider authorization updated",
                             receivedAt: now - 15, authorization: authorization)))
            try await runCLICommand(Status.self, ["status", "--config", sandbox.config.path])
        }
        let output = decodedText(result.standardOutputContent)

        #expect(output.contains("\nAuthorization: App Attest authorizes this connection. "))
        #expect(!output.contains("\nTrust: self_signed / online\n"))
        #expect(output.contains("MDM removal needs fresh coordinator readiness"))
        #expect(!output.contains("removal is available"))
        #expect(!output.contains("run \(BuildEnvironment.current.cliName) unenroll"))
    }
}
