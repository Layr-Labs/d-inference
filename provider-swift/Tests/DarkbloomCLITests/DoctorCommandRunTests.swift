import ArgumentParser
import Foundation
import ProviderCore
import Testing
#if canImport(Darwin)
import Darwin
#endif

@testable import darkbloom

/// End-to-end `darkbloom doctor` and `darkbloom verify` runs. Each run is in
/// its own child process with a temporary provider home and a stub
/// coordinator (`CLICommandSandbox`); the parent reads the printed report.
@Suite("Doctor command run")
struct DoctorCommandRunTests {

    static func attestationList(_ providers: [[String: Any]]) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["providers": providers])) ?? Data()
    }

    static func provider(
        id: String, key: String, trust: String, status: String, mdm: Bool, mda: Bool
    ) -> [String: Any] {
        [
            "provider_id": id, "chip_name": "Apple M4 Max", "hardware_model": "Mac16,5",
            "se_public_key": key, "trust_level": trust, "status": status,
            "mdm_verified": mdm, "mda_verified": mda, "secure_enclave": true,
            "sip_enabled": true, "secure_boot_enabled": true,
        ]
    }

    @Test("strict doctor with --support prints the report, the coordinator trust and the support block")
    func strictSupportRun() async throws {
        let result = try await #require(
            processExitsWith: .success, observing: [\.standardOutputContent]
        ) {
            let sandbox = try CLICommandSandbox.enter()
            defer { sandbox.remove() }
            try sandbox.writeToken("token-for-tests")
            try sandbox.makeModel("acme/Only-4bit")
            let now = Date().timeIntervalSince1970
            KVBackendGuardStore.write(
                KVBackendGuard(trippedAt: now - 300, providerVersion: ProviderCore.version, crashCount: 3))
            sandbox.writeState(try CLICommandSandbox.runningState(
                now: now,
                trust: .init(trustLevel: "hardware", status: "online", reason: "verified", receivedAt: now),
                attestationPublicKey: "attestation-key",
                advertisedModels: ["acme/Only-4bit"],
                stats: .init(requestsServed: 3, tokensGenerated: 30, usageGaps: 0),
                capacity: .init(
                    totalMemoryGb: 128, gpuMemoryActiveGb: 1, loadUsableGb: 100,
                    loadHeadroomGb: 2, freeForLoadGb: 90)))
            CoordinatorStub.install([
                "/health": .json(200, #"{"status":"ok"}"#),
                "/v1/providers/attestation": .init(status: 200, body: DoctorCommandRunTests.attestationList([
                    DoctorCommandRunTests.provider(
                        id: "provider-old", key: "attestation-key", trust: "self_signed",
                        status: "offline", mdm: false, mda: false),
                    DoctorCommandRunTests.provider(
                        id: "provider-live", key: "attestation-key", trust: "hardware",
                        status: "online", mdm: true, mda: false),
                    DoctorCommandRunTests.provider(
                        id: "provider-other", key: "other-key", trust: "hardware",
                        status: "online", mdm: true, mda: true),
                ])),
                "/v1/releases/latest": .init(
                    status: 200, body: CLICommandSandbox.releaseJSON(version: ProviderCore.version)),
            ])

            let error = try await runFailingCLICommand(
                Doctor.self, ["doctor", "--config", sandbox.config.path, "--strict", "--support"])
            // The active guard is a warning, and --strict makes warnings fail.
            #expect((error as? ExitCode) == .failure)
            #expect(CoordinatorStub.requests.contains { $0.url?.path == "/v1/providers/attestation" })
        }
        let output = decodedText(result.standardOutputContent)
        #expect(output.contains("darkbloom doctor \(ProviderCore.version)\n"))
        #expect(output.contains("/provider.toml\n"))
        #expect(output.contains("Daemon: running\n"))
        #expect(output.contains("READINESS: "))
        #expect(output.contains("DETAILED CHECKS\n"))
        #expect(output.contains("  [PASS] account link: auth token present\n"))
        #expect(output.contains("  [PASS] coordinator health: https://coordinator.invalid\n"))
        #expect(output.contains(
            "  [PASS] coordinator trust: provider-live online, trust=hardware, proofs=mdm\n"))
        #expect(output.contains("  [WARN] kv backend crash-loop guard: ACTIVE — "))
        #expect(output.contains("\nSupport\n  coordinator: https://coordinator.invalid\n  auth token: present\n  mdm enrolled: "))
        #expect(output.contains("  pid file: "))
    }

    @Test("an unreachable coordinator fails doctor, and a missing daemon tells the operator to start it")
    func unreachableCoordinator() async throws {
        let result = try await #require(
            processExitsWith: .success, observing: [\.standardOutputContent]
        ) {
            let sandbox = try CLICommandSandbox.enter()
            defer { sandbox.remove() }
            CoordinatorStub.install(["/health": .json(503, "unavailable")])

            let error = try await runFailingCLICommand(Doctor.self, ["doctor", "--config", sandbox.config.path])
            #expect((error as? ExitCode) == .failure)
            #expect(!CoordinatorStub.requests.contains { $0.url?.path == "/v1/providers/attestation" })
        }
        let output = decodedText(result.standardOutputContent)
        #expect(output.contains("Daemon: NOT running — run `darkbloom start`\n"))
        #expect(output.contains("  [WARN] account link: not logged in; run darkbloom login\n"))
        #expect(output.contains("  [FAIL] coordinator health: https://coordinator.invalid: "))
        #expect(!output.contains("coordinator trust:"))
        #expect(!output.contains("\nSupport\n"))
    }

    @Test("--clear-backend-guard clears the guard and the restart chain without running checks")
    func clearBackendGuardRun() async throws {
        let result = try await #require(
            processExitsWith: .success, observing: [\.standardOutputContent]
        ) {
            let sandbox = try CLICommandSandbox.enter()
            defer { sandbox.remove() }
            let now = Date().timeIntervalSince1970
            KVBackendGuardStore.write(
                KVBackendGuard(trippedAt: now - 60, providerVersion: ProviderCore.version, crashCount: 4))
            #expect(WatchdogStateStore.write(
                WatchdogState(lastRestartAt: now - 30, lastRestartVersion: ProviderCore.version,
                              consecutiveCrashLoopRestarts: 4),
                to: sandbox.watchdogStateFile))

            try await runCLICommand(Doctor.self, ["doctor", "--clear-backend-guard"])

            #expect(KVBackendGuardStore.read() == nil)
            let state = WatchdogStateStore.read(from: sandbox.watchdogStateFile)
            #expect(state.consecutiveCrashLoopRestarts == 0)
            #expect(state.lastRestartVersion == nil)
            #expect(CoordinatorStub.requests.isEmpty)
        }
        let output = decodedText(result.standardOutputContent)
        #expect(output.contains("Crash-loop KV-backend guard: tripped "))
        #expect(output.contains("after 4 crash-loop restarts."))
        #expect(output.contains("(was 4)"))
        #expect(output.contains("Cleared. "))
        #expect(!output.contains("DETAILED CHECKS"))
    }

    @Test("coordinator checks cover authorization, identity gaps, missing records and read errors")
    func coordinatorCheckBranches() async {
        await #expect(processExitsWith: .success) {
            let sandbox = try CLICommandSandbox.enter()
            defer { sandbox.remove() }
            let snapshot = try sandbox.snapshot(hardware: nil)
            func check(_ checks: [DoctorCheck], _ name: String) -> DoctorCheck? {
                checks.first { $0.name == name }
            }
            let healthy: [String: CoordinatorStub.Reply] = ["/health": .json(200, "{}")]

            // No daemon state: trust cannot be matched to a running process.
            CoordinatorStub.install(healthy)
            var checks = await buildCoordinatorDoctorChecks(snapshot: snapshot, coordinatorOverride: nil)
            #expect(check(checks, "account link")?.status == .warn)
            #expect(check(checks, "coordinator health")?.detail == "https://coordinator.invalid")
            #expect(check(checks, "coordinator trust")?.status == .warn)
            #expect(check(checks, "coordinator trust")?.detail
                == DoctorAttestationIdentityUnavailable.daemonStateMissing.detail)
            #expect(check(checks, "mdm enrollment") != nil)

            // A running daemon that does not report its signer key.
            var now = Date().timeIntervalSince1970
            sandbox.writeState(try CLICommandSandbox.runningState(now: now))
            checks = await buildCoordinatorDoctorChecks(snapshot: snapshot, coordinatorOverride: nil)
            #expect(check(checks, "coordinator trust")?.detail
                == DoctorAttestationIdentityUnavailable.signerIdentityNotReported.detail)

            // The coordinator has no record for this key.
            try sandbox.writeToken("token-for-tests")
            now = Date().timeIntervalSince1970
            sandbox.writeState(try CLICommandSandbox.runningState(now: now, attestationPublicKey: "attestation-key"))
            CoordinatorStub.install(healthy.merging([
                "/v1/providers/attestation": .init(status: 200, body: DoctorCommandRunTests.attestationList([
                    DoctorCommandRunTests.provider(
                        id: "provider-other", key: "other-key", trust: "hardware",
                        status: "online", mdm: true, mda: true),
                ])),
            ]) { $1 })
            checks = await buildCoordinatorDoctorChecks(snapshot: snapshot, coordinatorOverride: nil)
            #expect(check(checks, "account link")?.detail == "auth token present")
            #expect(check(checks, "coordinator trust")?.status == .warn)
            #expect(check(checks, "coordinator trust")?.detail
                == "no live provider record for the running daemon's attestation identity yet")

            // A self-signed record names the pending MDM proof.
            CoordinatorStub.install(healthy.merging([
                "/v1/providers/attestation": .init(status: 200, body: DoctorCommandRunTests.attestationList([
                    DoctorCommandRunTests.provider(
                        id: "provider-new", key: "attestation-key", trust: "self_signed",
                        status: "online", mdm: false, mda: false),
                ])),
            ]) { $1 })
            checks = await buildCoordinatorDoctorChecks(snapshot: snapshot, coordinatorOverride: nil)
            #expect(check(checks, "coordinator trust")?.status == .warn)
            #expect(check(checks, "coordinator trust")?.detail
                == "provider-new online, trust=self_signed, proofs=self-signed only, mdm=pending "
                + "(coordinator's live MDM SecurityInfo check not yet passed)")

            // Both proofs are listed in order.
            CoordinatorStub.install(healthy.merging([
                "/v1/providers/attestation": .init(status: 200, body: DoctorCommandRunTests.attestationList([
                    DoctorCommandRunTests.provider(
                        id: "provider-both", key: "attestation-key", trust: "hardware",
                        status: "online", mdm: true, mda: true),
                ])),
            ]) { $1 })
            checks = await buildCoordinatorDoctorChecks(snapshot: snapshot, coordinatorOverride: nil)
            #expect(check(checks, "coordinator trust")?.status == .pass)
            #expect(check(checks, "coordinator trust")?.detail
                == "provider-both online, trust=hardware, proofs=mdm,mda")

            // The attestation endpoint fails.
            CoordinatorStub.install(healthy.merging([
                "/v1/providers/attestation": .json(500, "boom"),
            ]) { $1 })
            checks = await buildCoordinatorDoctorChecks(snapshot: snapshot, coordinatorOverride: nil)
            #expect(check(checks, "coordinator trust")?.detail.hasPrefix(
                "could not read attestation endpoint: ") == true)

            // A current App Attest authorization replaces the attestation lookup.
            CoordinatorStub.install(healthy)
            now = Date().timeIntervalSince1970
            sandbox.writeState(try CLICommandSandbox.runningState(
                now: now,
                trust: .init(
                    trustLevel: "self_signed", status: "online", reason: "app attest", receivedAt: now,
                    authorization: CLICommandSandbox.appAttestAuthorization(now: now)),
                attestationPublicKey: "attestation-key"))
            checks = await buildCoordinatorDoctorChecks(snapshot: snapshot, coordinatorOverride: nil)
            #expect(check(checks, "serving authorization")?.status == .pass)
            #expect(check(checks, "serving authorization")?.detail.hasPrefix(
                "App Attest authorizes this connection.") == true)
            #expect(check(checks, "coordinator trust") == nil)
            #expect(!CoordinatorStub.requests.contains { $0.url?.path == "/v1/providers/attestation" })

            // An override coordinator is used for every request; the state
            // file names a different coordinator, so its authorization does
            // not apply.
            CoordinatorStub.install(healthy)
            checks = await buildCoordinatorDoctorChecks(
                snapshot: snapshot, coordinatorOverride: "wss://override.invalid/ws/provider")
            #expect(check(checks, "coordinator health")?.detail == "https://override.invalid")
            #expect(check(checks, "serving authorization") == nil)
            #expect(CoordinatorStub.requests.allSatisfy { $0.url?.host == "override.invalid" })
        }
    }

    @Test("verify prints every check and fails when one is not a pass")
    func verifyRun() async throws {
        let result = try await #require(
            processExitsWith: .success, observing: [\.standardOutputContent]
        ) {
            let sandbox = try CLICommandSandbox.enter()
            defer { sandbox.remove() }
            CoordinatorStub.install(["/health": .json(200, "{}")])
            let error = try await runFailingCLICommand(
                Verify.self, ["verify", "--config", sandbox.config.path])
            #expect((error as? ExitCode) == .failure)
        }
        let output = decodedText(result.standardOutputContent)
        #expect(output.contains("darkbloom verify\nConfig: "))
        #expect(output.contains("[PASS] coordinator health: https://coordinator.invalid\n"))
        #expect(output.contains("[WARN] account link: not logged in; run darkbloom login\n"))
        #expect(output.contains(
            "[WARN] coordinator trust: \(DoctorAttestationIdentityUnavailable.daemonStateMissing.detail)\n"))
    }

    @Test("verify accepts a coordinator override")
    func verifyParsesOverride() throws {
        let verify = try #require(try Darkbloom.parseAsRoot(
            ["verify", "--coordinator", "https://override.invalid"]) as? Verify)
        #expect(verify.coordinator == "https://override.invalid")
    }

    @Test("doctor flags parse into their properties")
    func doctorFlagsParse() throws {
        let doctor = try #require(try Darkbloom.parseAsRoot([
            "doctor", "--strict", "--support", "--coordinator", "https://override.invalid",
        ]) as? Doctor)
        #expect(doctor.strict)
        #expect(doctor.support)
        #expect(doctor.coordinator == "https://override.invalid")
        #expect(!doctor.clearBackendGuard)
        #expect(try Doctor.parse(["--clear-backend-guard"]).clearBackendGuard)
    }

    @Test("strict mode turns warnings into failures; info never fails")
    func strictFailureRule() {
        #expect(DiagnosticLevel.fail.isFailure(strict: false))
        #expect(!DiagnosticLevel.warn.isFailure(strict: false))
        #expect(DiagnosticLevel.warn.isFailure(strict: true))
        #expect(!DiagnosticLevel.info.isFailure(strict: true))
        #expect(!DiagnosticLevel.pass.isFailure(strict: true))
    }
}

/// The failure paths of `doctor --clear-backend-guard` when files cannot
/// be changed. The command takes its paths as parameters, so these run in
/// the test process on temporary folders.
@Suite("Doctor clear-backend-guard write failures")
struct DoctorClearBackendGuardFailureTests {
    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("clear-guard-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test("a guard record that cannot be removed fails the command and keeps the chain")
    func guardRemovalFails() throws {
        guard geteuid() != 0 else { return } // Root ignores the folder permission used here.
        let folder = try temporaryFolder()
        let locked = folder.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: folder)
        }
        let environment = [KVBackendGuardStore.pathEnvKey: locked.appendingPathComponent("guard.json").path]
        #expect(KVBackendGuardStore.write(
            KVBackendGuard(trippedAt: 9_000, providerVersion: "0.8.0", crashCount: 3),
            environment: environment))
        let stateURL = folder.appendingPathComponent("watchdog-state.json")
        #expect(WatchdogStateStore.write(
            WatchdogState(lastRestartAt: 9_500, lastRestartVersion: "0.8.0", consecutiveCrashLoopRestarts: 3),
            to: stateURL))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)

        var lines: [String] = []
        #expect(throws: ExitCode.failure) {
            try Doctor.runClearBackendGuard(
                environment: environment, watchdogStateURL: stateURL, now: 10_000,
                output: { lines.append($0) })
        }
        #expect(lines.count == 1)
        #expect(lines.first?.hasPrefix("Crash-loop KV-backend guard: tripped ") == true)
        #expect(lines.first?.hasSuffix("ago on v0.8.0 after 3 crash-loop restarts.") == true)
        #expect(KVBackendGuardStore.read(environment: environment, now: 10_000) != nil)
        #expect(WatchdogStateStore.read(from: stateURL).consecutiveCrashLoopRestarts == 3)
    }

    @Test("a restart chain that cannot be saved is reported as a warning after the guard is cleared")
    func chainResetFails() throws {
        guard geteuid() != 0 else { return } // Root ignores the folder permission used here.
        let folder = try temporaryFolder()
        let locked = folder.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? FileManager.default.removeItem(at: folder)
        }
        let environment = [KVBackendGuardStore.pathEnvKey: folder.appendingPathComponent("guard.json").path]
        #expect(KVBackendGuardStore.write(
            KVBackendGuard(trippedAt: 9_000, providerVersion: "0.8.0", crashCount: 3),
            environment: environment))
        let stateURL = locked.appendingPathComponent("watchdog-state.json")
        #expect(WatchdogStateStore.write(
            WatchdogState(lastRestartAt: 9_500, lastRestartVersion: "0.8.0", consecutiveCrashLoopRestarts: 3),
            to: stateURL))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)

        var lines: [String] = []
        try Doctor.runClearBackendGuard(
            environment: environment, watchdogStateURL: stateURL, now: 10_000,
            output: { lines.append($0) })

        #expect(KVBackendGuardStore.read(environment: environment, now: 10_000) == nil)
        #expect(lines.contains {
            $0.hasPrefix("WARNING: could not reset the crash-loop restart chain at \(stateURL.path)")
        })
        #expect(lines.last?.hasPrefix("Cleared. ") == true)
        #expect(WatchdogStateStore.read(from: stateURL).consecutiveCrashLoopRestarts == 3)
    }
}
