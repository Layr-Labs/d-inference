import Foundation
import ProviderCoreFoundation
import Testing
@testable import DarkbloomApp

/// The verification step's REAL gating: phases follow the daemon's
/// `daemon-state.json` trust (ProviderCoreFoundation.DaemonStateFile.read via
/// the injected provider), not timers. Tests drive the REAL reader/writer
/// against a temp file and an accelerated clock.
@Suite("Onboarding live verification gating")
@MainActor
struct OnboardingVerificationGatingTests {
    private static let modelID = "catalog/verification-model"

    private struct Fixture {
        let directory: URL
        let stateURL: URL
        var writtenAt: Double = Date().timeIntervalSince1970
    }

    private func makeFixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("verification-gating-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return Fixture(
            directory: directory,
            stateURL: directory.appendingPathComponent("daemon-state.json")
        )
    }

    private func writeTrust(
        _ trust: DaemonState.Trust?,
        to fixture: Fixture,
        pid: Int32 = Int32(ProcessInfo.processInfo.processIdentifier),
        modelID: String = Self.modelID,
        processIdentity: ProcessIdentity? = ProcessIdentity.current()
    ) {
        let state = DaemonState(
            pid: pid,
            processIdentity: processIdentity,
            version: "0.0.0-test",
            writtenAt: fixture.writtenAt,
            startedAt: fixture.writtenAt,
            trust: trust,
            currentModel: modelID,
            warmModels: [modelID]
        )
        DaemonStateFile.write(state, to: fixture.stateURL)
    }

    private func trust(status: String, level: String = "self_signed") -> DaemonState.Trust {
        DaemonState.Trust(
            trustLevel: level,
            status: status,
            reason: "",
            receivedAt: Date().timeIntervalSince1970
        )
    }

    private func makeFlow(
        stateURL: URL,
        verificationCheckInGrace: Duration = .seconds(30)
    ) -> OnboardingFlowModel {
        let flow = OnboardingFlowModel(
            startingAt: .verification,
            accountLinkRunner: nil,
            daemonStateProvider: { DaemonStateFile.read(from: stateURL) },
            providerEvidenceProvider: {
                let state = DaemonStateFile.read(from: stateURL)
                let endpoint = state.map {
                    LocalEndpointInfo(
                        host: "127.0.0.1",
                        port: 18080,
                        apiKey: "test",
                        version: "test",
                        pid: $0.pid,
                        updatedAt: "2026-01-01T00:00:00Z"
                    )
                }
                return OnboardingProviderEvidence(
                    daemonState: state,
                    localEndpoint: endpoint
                )
            },
            verificationPollInterval: .milliseconds(10),
            verificationCheckInGrace: verificationCheckInGrace
        )
        flow.selectedModelID = Self.modelID
        return flow
    }

    private func eventually(_ predicate: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate()
    }

    @Test("profile accepted → trust pending → verified follows the live trust file")
    func progressionProfiles() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let flow = makeFlow(stateURL: fixture.stateURL)
        #expect(flow.usesLiveVerification)

        let run = Task { await flow.runAutomaticWorkForCurrentStep() }

        // No daemon state yet: waiting for the server check-in.
        let pending = await eventually { flow.verificationPhase == .enrollmentPending }
        #expect(pending)
        #expect(!flow.canContinue)

        // Check-in happened but trust is pending (e.g. "SE attestation
        // verified, awaiting MDM verification").
        writeTrust(trust(status: "pending"), to: fixture)
        let trustPending = await eventually { flow.verificationPhase == .trustPending }
        #expect(trustPending)
        #expect(!flow.canContinue)

        // Coordinator grants hardware trust.
        writeTrust(trust(status: "verified", level: "hardware"), to: fixture)
        let trusted = await eventually { flow.verificationPhase == .hardwareTrusted }
        #expect(trusted)
        await run.value
        #expect(flow.canContinue)

        flow.continueToNextStep()
        #expect(flow.step == .complete)
    }

    @Test("mda_verified trust level alone also unlocks the gate")
    func mdaVerifiedLevelPasses() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let flow = makeFlow(stateURL: fixture.stateURL)

        let run = Task { await flow.runAutomaticWorkForCurrentStep() }
        writeTrust(trust(status: "online", level: "mda_verified"), to: fixture)
        let trusted = await eventually { flow.verificationPhase == .hardwareTrusted }
        #expect(trusted)
        await run.value
    }

    @Test("A live PID without kernel identity cannot unlock verification")
    func identitylessProviderCannotPass() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let flow = makeFlow(
            stateURL: fixture.stateURL,
            verificationCheckInGrace: .milliseconds(300))
        writeTrust(
            trust(status: "verified", level: "hardware"),
            to: fixture,
            processIdentity: nil
        )

        let run = Task { await flow.runAutomaticWorkForCurrentStep() }
        let delayed = await eventually { flow.verificationPhase == .checkInDelayed }
        #expect(delayed)
        #expect(!flow.canContinue)
        flow.cancelPendingOperations()
        await run.value
    }

    @Test("A fresh verified state file with a dead PID cannot unlock verification")
    func deadProviderCannotPass() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let flow = makeFlow(
            stateURL: fixture.stateURL,
            verificationCheckInGrace: .milliseconds(300))
        writeTrust(
            trust(status: "verified", level: "hardware"),
            to: fixture,
            pid: Int32.max,
            processIdentity: ProcessIdentity(pid: Int32.max, startTimeMicros: 1)
        )

        let run = Task { await flow.runAutomaticWorkForCurrentStep() }
        let delayed = await eventually { flow.verificationPhase == .checkInDelayed }
        #expect(delayed)
        #expect(!flow.canContinue)
        flow.cancelPendingOperations()
        await run.value
    }

    @Test("Completion rechecks live selected-model evidence after trust was granted")
    func completionRechecksProviderEvidence() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let flow = makeFlow(stateURL: fixture.stateURL)

        let run = Task { await flow.runAutomaticWorkForCurrentStep() }
        writeTrust(trust(status: "verified", level: "hardware"), to: fixture)
        #expect(await eventually { flow.verificationPhase == .hardwareTrusted })
        await run.value
        #expect(flow.canContinue)

        writeTrust(
            trust(status: "verified", level: "hardware"),
            to: fixture,
            modelID: "catalog/different-model"
        )
        #expect(!flow.canContinue)
        flow.continueToNextStep()
        #expect(flow.step == .verification)
    }

    @Test("A success status without hardware trust stays pending")
    func verifiedSelfSignedDoesNotPass() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let flow = makeFlow(stateURL: fixture.stateURL)

        let run = Task { await flow.runAutomaticWorkForCurrentStep() }
        writeTrust(trust(status: "verified", level: "self_signed"), to: fixture)
        let pending = await eventually { flow.verificationPhase == .trustPending }
        #expect(pending)
        #expect(!flow.canContinue)
        flow.cancelPendingOperations()
        await run.value
    }

    @Test("A refused trust status stops the gate as trustFailed; retry re-polls the file")
    func refusalThenRetry() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let flow = makeFlow(stateURL: fixture.stateURL)

        let run = Task { await flow.runAutomaticWorkForCurrentStep() }
        writeTrust(trust(status: "denied"), to: fixture)
        let failed = await eventually { flow.verificationPhase == .trustFailed }
        #expect(failed)
        await run.value
        #expect(!flow.canContinue)

        // Recovery: the daemon later reports trust (user re-ran checks); the
        // retry path must re-poll rather than replay the failure.
        writeTrust(trust(status: "verified", level: "hardware"), to: fixture)
        await flow.retryVerification()
        #expect(flow.verificationPhase == .hardwareTrusted)
        #expect(flow.canContinue)
    }

    @Test("status 'offline' splits out of the failing set as a connection problem")
    func offlineTrust() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let flow = makeFlow(stateURL: fixture.stateURL)

        let run = Task { await flow.runAutomaticWorkForCurrentStep() }
        writeTrust(trust(status: "offline"), to: fixture)
        let offline = await eventually { flow.verificationPhase == .offline }
        #expect(offline)
        await run.value
        #expect(!flow.canContinue)
    }

    @Test("No daemon state past the grace window marks checkInDelayed and self-heals")
    func delayedCheckInSelfHeals() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let flow = makeFlow(
            stateURL: fixture.stateURL,
            verificationCheckInGrace: .milliseconds(300))

        let run = Task { await flow.runAutomaticWorkForCurrentStep() }
        let delayed = await eventually { flow.verificationPhase == .checkInDelayed }
        #expect(delayed)
        #expect(!flow.canContinue)

        // Late check-in still routes through without any user action.
        writeTrust(trust(status: "verified", level: "hardware"), to: fixture)
        let trusted = await eventually { flow.verificationPhase == .hardwareTrusted }
        #expect(trusted)
        await run.value
    }

    @Test("Cancellation stops the poll without a terminal verdict")
    func cancellationStopsPolling() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let flow = makeFlow(stateURL: fixture.stateURL)

        let run = Task { await flow.runAutomaticWorkForCurrentStep() }
        let pending = await eventually { flow.verificationPhase == .enrollmentPending }
        #expect(pending)

        flow.cancelPendingOperations()
        await run.value
        #expect(flow.verificationPhase == .enrollmentPending)

        // A trust grant arriving after cancellation must not advance the gate.
        writeTrust(trust(status: "verified", level: "hardware"), to: fixture)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(flow.verificationPhase == .enrollmentPending)
        #expect(!flow.canContinue)
    }
}
