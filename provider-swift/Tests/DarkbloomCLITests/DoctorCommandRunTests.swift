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

    /// Old enough that the strict 10-second check withholds a report, later
    /// than the sandbox state's process start, and early in its minute so
    /// the age still prints as "10m" when a command takes a while to run.
    static let agedReceiptSeconds: Double = 605

    static let legacyReport = ProviderAuthorizationStatus(
        appAttestAvailable: false, path: "legacy", sessionID: "session-1", machineID: "")
    static let deniedReport = ProviderAuthorizationStatus(
        appAttestAvailable: true, path: "none", reason: "device not qualified",
        sessionID: "session-1", machineID: "")

    /// The `last reported authorization` text for each report at that age.
    static let legacyHistory = "received 10m ago; not a fresh dispatch grant. "
        + "Serving through legacy verification; keep the Darkbloom MDM profile."
    static let deniedHistory = "received 10m ago; not a fresh dispatch grant. "
        + "The coordinator supports App Attest, but this connection is not currently qualified. "
        + "Keep existing management in place. device not qualified"

    /// Daemon state this test process writes now, holding a coordinator
    /// report that arrived at `receivedAt`. The process identity and the
    /// coordinator are the sandbox's own, so a test changes only the
    /// report and its timestamps.
    static func reportedState(
        _ authorization: ProviderAuthorizationStatus, receivedAt: Double, writtenAt: Double? = nil
    ) throws -> DaemonState {
        try CLICommandSandbox.runningState(
            now: Date().timeIntervalSince1970,
            writtenAt: writtenAt,
            trust: .init(
                trustLevel: "self_signed", status: "online", reason: authorization.path,
                receivedAt: receivedAt, authorization: authorization),
            attestationPublicKey: "attestation-key")
    }

    /// Rewrites the daemon state while a command runs, as a running provider
    /// keeps its snapshot current. `verify` runs its local checks before it
    /// reads the state, and the snapshot write must be at most 10 seconds
    /// old by then. The receipt time stays fixed.
    static func keepStateCurrent(
        _ authorization: ProviderAuthorizationStatus, receivedAt: Double, in sandbox: CLICommandSandbox
    ) -> Task<Void, Never> {
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled,
                      let state = try? DoctorCommandRunTests.reportedState(authorization, receivedAt: receivedAt)
                else { continue }
                sandbox.writeState(state)
            }
        }
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

    @Test("an aged legacy or none report is listed as history and the attestation lookup still runs")
    func agedReportKeepsAttestationLookup() async {
        await #expect(processExitsWith: .success) {
            let sandbox = try CLICommandSandbox.enter()
            defer { sandbox.remove() }
            try sandbox.writeToken("token-for-tests")
            let snapshot = try sandbox.snapshot(hardware: nil)
            func check(_ checks: [DoctorCheck], _ name: String) -> DoctorCheck? {
                checks.first { $0.name == name }
            }
            func attestationLookups() -> Int {
                CoordinatorStub.requests.filter { $0.url?.path == "/v1/providers/attestation" }.count
            }
            // The coordinator's public record proves the running daemon's key.
            let proven: [String: CoordinatorStub.Reply] = [
                "/health": .json(200, "{}"),
                "/v1/providers/attestation": .init(status: 200, body: DoctorCommandRunTests.attestationList([
                    DoctorCommandRunTests.provider(
                        id: "provider-live", key: "attestation-key", trust: "hardware",
                        status: "online", mdm: true, mda: false),
                ])),
            ]
            let aged = DoctorCommandRunTests.agedReceiptSeconds

            // A legacy report past the strict limit is information, and the
            // trust row still comes from the attestation endpoint.
            CoordinatorStub.install(proven)
            var now = Date().timeIntervalSince1970
            sandbox.writeState(try DoctorCommandRunTests.reportedState(
                DoctorCommandRunTests.legacyReport, receivedAt: now - aged))
            var checks = await buildCoordinatorDoctorChecks(snapshot: snapshot, coordinatorOverride: nil)
            #expect(check(checks, "serving authorization") == nil)
            #expect(check(checks, "last reported authorization")?.status == .info)
            #expect(check(checks, "last reported authorization")?.detail == DoctorCommandRunTests.legacyHistory)
            #expect(check(checks, "coordinator trust")?.status == .pass)
            #expect(check(checks, "coordinator trust")?.detail
                == "provider-live online, trust=hardware, proofs=mdm")
            #expect(attestationLookups() == 1)
            // The only row that can still fail a strict run is this
            // machine's own MDM enrollment.
            #expect(!checks.contains { $0.name != "mdm enrollment" && $0.status.isFailure(strict: true) })

            // A none report of the same age is a warning. The lookup runs
            // and passes, and the warning still fails a strict run.
            CoordinatorStub.install(proven)
            now = Date().timeIntervalSince1970
            sandbox.writeState(try DoctorCommandRunTests.reportedState(
                DoctorCommandRunTests.deniedReport, receivedAt: now - aged))
            checks = await buildCoordinatorDoctorChecks(snapshot: snapshot, coordinatorOverride: nil)
            #expect(check(checks, "serving authorization") == nil)
            #expect(check(checks, "last reported authorization")?.status == .warn)
            #expect(check(checks, "last reported authorization")?.detail == DoctorCommandRunTests.deniedHistory)
            #expect(check(checks, "coordinator trust")?.status == .pass)
            #expect(attestationLookups() == 1)
            #expect(checks.filter { $0.name != "mdm enrollment" && $0.status.isFailure(strict: true) }
                .map(\.name) == ["last reported authorization"])
            #expect(!checks.contains { $0.status.isFailure(strict: false) })

            // The same reports received just now take the strict branch: one
            // authorization row, no history row and no attestation lookup.
            let current: [(ProviderAuthorizationStatus, DiagnosticLevel)] = [
                (DoctorCommandRunTests.legacyReport, .pass), (DoctorCommandRunTests.deniedReport, .warn),
            ]
            for (report, level) in current {
                CoordinatorStub.install(proven)
                now = Date().timeIntervalSince1970
                sandbox.writeState(try DoctorCommandRunTests.reportedState(report, receivedAt: now))
                checks = await buildCoordinatorDoctorChecks(snapshot: snapshot, coordinatorOverride: nil)
                #expect(check(checks, "serving authorization")?.status == level)
                #expect(check(checks, "last reported authorization") == nil)
                #expect(check(checks, "coordinator trust") == nil)
                #expect(attestationLookups() == 0)
            }
        }
    }

    @Test("an aged legacy or none report never stands in for a missing, mismatched or unreadable public proof")
    func agedReportNeverReplacesPublicProof() async {
        await #expect(processExitsWith: .success) {
            let sandbox = try CLICommandSandbox.enter()
            defer { sandbox.remove() }
            try sandbox.writeToken("token-for-tests")
            let snapshot = try sandbox.snapshot(hardware: nil)
            let reports: [(report: ProviderAuthorizationStatus, level: DiagnosticLevel)] = [
                (DoctorCommandRunTests.legacyReport, .info), (DoctorCommandRunTests.deniedReport, .warn),
            ]
            let noRecord = "no live provider record for the running daemon's attestation identity yet"
            let proofs: [(reply: CoordinatorStub.Reply, detail: String)] = [
                // The coordinator lists no provider.
                (.init(status: 200, body: DoctorCommandRunTests.attestationList([])), noRecord),
                // The only proven record belongs to another key.
                (.init(status: 200, body: DoctorCommandRunTests.attestationList([
                    DoctorCommandRunTests.provider(
                        id: "provider-other", key: "other-key", trust: "hardware",
                        status: "online", mdm: true, mda: true),
                ])), noRecord),
                // The record for this key carries no hardware proof.
                (.init(status: 200, body: DoctorCommandRunTests.attestationList([
                    DoctorCommandRunTests.provider(
                        id: "provider-new", key: "attestation-key", trust: "self_signed",
                        status: "online", mdm: false, mda: false),
                ])), "provider-new online, trust=self_signed, proofs=self-signed only, mdm=pending "
                    + "(coordinator's live MDM SecurityInfo check not yet passed)"),
                // The attestation endpoint fails.
                (.json(500, "boom"), "could not read attestation endpoint: "),
            ]

            for (report, level) in reports {
                for proof in proofs {
                    CoordinatorStub.install([
                        "/health": .json(200, "{}"), "/v1/providers/attestation": proof.reply,
                    ])
                    let now = Date().timeIntervalSince1970
                    sandbox.writeState(try DoctorCommandRunTests.reportedState(
                        report, receivedAt: now - DoctorCommandRunTests.agedReceiptSeconds))
                    let checks = await buildCoordinatorDoctorChecks(snapshot: snapshot, coordinatorOverride: nil)
                    let history = checks.first { $0.name == "last reported authorization" }
                    let trust = checks.first { $0.name == "coordinator trust" }
                    #expect(history?.status == level)
                    #expect(!checks.contains { $0.name == "serving authorization" })
                    #expect(CoordinatorStub.requests.contains { $0.url?.path == "/v1/providers/attestation" })
                    // The trust row is a warning whatever the report said,
                    // so a strict run fails on it.
                    #expect(trust?.status == .warn)
                    #expect(trust?.detail.hasPrefix(proof.detail) == true)
                    #expect(trust?.status.isFailure(strict: true) == true)
                }
            }
        }
    }

    @Test("history is withheld for App Attest, a pre-start receipt, a stale snapshot and another coordinator")
    func agedReportGuards() async {
        await #expect(processExitsWith: .success) {
            let sandbox = try CLICommandSandbox.enter()
            defer { sandbox.remove() }
            try sandbox.writeToken("token-for-tests")
            let snapshot = try sandbox.snapshot(hardware: nil)
            func check(_ checks: [DoctorCheck], _ name: String) -> DoctorCheck? {
                checks.first { $0.name == name }
            }
            let proven: [String: CoordinatorStub.Reply] = [
                "/health": .json(200, "{}"),
                "/v1/providers/attestation": .init(status: 200, body: DoctorCommandRunTests.attestationList([
                    DoctorCommandRunTests.provider(
                        id: "provider-live", key: "attestation-key", trust: "hardware",
                        status: "online", mdm: true, mda: false),
                ])),
            ]
            let aged = DoctorCommandRunTests.agedReceiptSeconds

            // An App Attest decision of that age is never history. While its
            // lease is unexpired it is still the coordinator's grant
            // (`displayedStatus`), so it is the serving authorization row;
            // once the lease has expired no row names it, and the enrollment
            // row does not treat the connection as authorized.
            CoordinatorStub.install(proven)
            var now = Date().timeIntervalSince1970
            sandbox.writeState(try DoctorCommandRunTests.reportedState(
                CLICommandSandbox.appAttestAuthorization(now: now), receivedAt: now - aged))
            var checks = await buildCoordinatorDoctorChecks(snapshot: snapshot, coordinatorOverride: nil)
            #expect(check(checks, "last reported authorization") == nil)
            #expect(check(checks, "serving authorization")?.status == .pass)
            #expect(check(checks, "coordinator trust") == nil)

            CoordinatorStub.install(proven)
            now = Date().timeIntervalSince1970
            var lapsed = CLICommandSandbox.appAttestAuthorization(now: now)
            lapsed.expiresAt = now - 5
            sandbox.writeState(try DoctorCommandRunTests.reportedState(lapsed, receivedAt: now - aged))
            checks = await buildCoordinatorDoctorChecks(snapshot: snapshot, coordinatorOverride: nil)
            #expect(check(checks, "last reported authorization") == nil)
            #expect(check(checks, "serving authorization") == nil)
            #expect(!checks.contains {
                $0.detail.contains("App Attest authorizes") || $0.detail.contains("App Attest-authorized")
            })
            #expect(check(checks, "coordinator trust")?.status == .pass)

            // A legacy report received before this process started. The
            // sandbox state starts 3,700 seconds before it is written.
            CoordinatorStub.install(proven)
            now = Date().timeIntervalSince1970
            sandbox.writeState(try DoctorCommandRunTests.reportedState(
                DoctorCommandRunTests.legacyReport, receivedAt: now - 4_000))
            checks = await buildCoordinatorDoctorChecks(snapshot: snapshot, coordinatorOverride: nil)
            #expect(check(checks, "last reported authorization") == nil)
            #expect(check(checks, "coordinator trust")?.status == .pass)

            // A none report in a snapshot written 20 seconds ago. The
            // snapshot is still recent enough to match the trust record.
            CoordinatorStub.install(proven)
            now = Date().timeIntervalSince1970
            sandbox.writeState(try DoctorCommandRunTests.reportedState(
                DoctorCommandRunTests.deniedReport, receivedAt: now - aged, writtenAt: now - 20))
            checks = await buildCoordinatorDoctorChecks(snapshot: snapshot, coordinatorOverride: nil)
            #expect(check(checks, "last reported authorization") == nil)
            #expect(check(checks, "coordinator trust")?.status == .pass)

            // A legacy report from the configured coordinator, checked
            // against an override coordinator.
            CoordinatorStub.install(proven)
            now = Date().timeIntervalSince1970
            sandbox.writeState(try DoctorCommandRunTests.reportedState(
                DoctorCommandRunTests.legacyReport, receivedAt: now - aged))
            checks = await buildCoordinatorDoctorChecks(
                snapshot: snapshot, coordinatorOverride: "wss://override.invalid/ws/provider")
            #expect(check(checks, "last reported authorization") == nil)
            #expect(check(checks, "coordinator health")?.detail == "https://override.invalid")
        }
    }

    @Test("verify prints every check and fails when one is a warning or a failure")
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

    @Test("verify prints an aged legacy report as information and fails on an aged none report or an unproven key")
    func verifyAgedReports() async throws {
        let result = try await #require(
            processExitsWith: .success, observing: [\.standardOutputContent]
        ) {
            let sandbox = try CLICommandSandbox.enter()
            defer { sandbox.remove() }
            try sandbox.writeToken("token-for-tests")
            // The coordinator's hardware-proven record is for `provenKey`;
            // the running daemon's key is "attestation-key".
            let runs: [(label: String, report: ProviderAuthorizationStatus, provenKey: String)] = [
                ("legacy-proven", DoctorCommandRunTests.legacyReport, "attestation-key"),
                ("legacy-unproven", DoctorCommandRunTests.legacyReport, "other-key"),
                ("none-proven", DoctorCommandRunTests.deniedReport, "attestation-key"),
            ]
            for run in runs {
                CoordinatorStub.install([
                    "/health": .json(200, "{}"),
                    "/v1/providers/attestation": .init(status: 200, body: DoctorCommandRunTests.attestationList([
                        DoctorCommandRunTests.provider(
                            id: "provider-live", key: run.provenKey, trust: "hardware",
                            status: "online", mdm: true, mda: false),
                    ])),
                ])
                let receivedAt = Date().timeIntervalSince1970 - DoctorCommandRunTests.agedReceiptSeconds
                sandbox.writeState(try DoctorCommandRunTests.reportedState(run.report, receivedAt: receivedAt))
                let heartbeat = DoctorCommandRunTests.keepStateCurrent(
                    run.report, receivedAt: receivedAt, in: sandbox)
                print("begin \(run.label)")
                let error = try await runFailingCLICommand(
                    Verify.self, ["verify", "--config", sandbox.config.path])
                heartbeat.cancel()
                await heartbeat.value
                #expect(error == nil || (error as? ExitCode) == .failure)
                #expect(CoordinatorStub.requests.contains { $0.url?.path == "/v1/providers/attestation" })
                print("verify-failed \(error != nil)")
                print("end \(run.label)")
            }
        }
        let output = decodedText(result.standardOutputContent)
        let legacyRow = "[INFO] last reported authorization: \(DoctorCommandRunTests.legacyHistory)\n"
        let provenRow = "[PASS] coordinator trust: provider-live online, trust=hardware, proofs=mdm\n"
        #expect(!output.contains("serving authorization:"))

        // Historical legacy with a proven key. Whether verify passes here
        // depends on this machine's own checks, so the exit status is
        // compared with the rows verify printed: it fails only when one of
        // them is a WARN or a FAIL, and the INFO row is neither.
        let proven = try #require(outputSection(output, from: "begin legacy-proven", to: "end legacy-proven"))
        #expect(proven.contains(legacyRow))
        #expect(proven.contains(provenRow))
        let failingRows = proven.split(separator: "\n").filter {
            $0.hasPrefix("[WARN] ") || $0.hasPrefix("[FAIL] ")
        }
        #expect(printedValue(proven, label: "verify-failed") == "\(!failingRows.isEmpty)")

        // Historical legacy with no record for this key: the INFO row does
        // not stand in for the proof, so verify fails on any machine.
        let unproven = try #require(
            outputSection(output, from: "begin legacy-unproven", to: "end legacy-unproven"))
        #expect(unproven.contains(legacyRow))
        #expect(unproven.contains(
            "[WARN] coordinator trust: no live provider record for the running daemon's "
            + "attestation identity yet\n"))
        #expect(printedValue(unproven, label: "verify-failed") == "true")

        // Historical none with a proven key: the denial is a WARN, and the
        // passing proof does not keep verify from failing on any machine.
        let denied = try #require(outputSection(output, from: "begin none-proven", to: "end none-proven"))
        #expect(denied.contains(
            "[WARN] last reported authorization: \(DoctorCommandRunTests.deniedHistory)\n"))
        #expect(denied.contains(provenRow))
        #expect(printedValue(denied, label: "verify-failed") == "true")
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
