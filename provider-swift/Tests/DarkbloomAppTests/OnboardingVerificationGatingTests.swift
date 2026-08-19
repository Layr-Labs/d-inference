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

    private func writeTrust(_ trust: DaemonState.Trust?, to fixture: Fixture) {
        let state = DaemonState(
            pid: 1,
            version: "0.0.0-test",
            writtenAt: fixture.writtenAt,
            startedAt: fixture.writtenAt,
            trust: trust
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

    private func makeFlow(stateURL: URL) -> OnboardingFlowModel {
        OnboardingFlowModel(
            startingAt: .verification,
            accountLinkRunner: nil,
            daemonStateProvider: { DaemonStateFile.read(from: stateURL) },
            verificationPollInterval: .milliseconds(10),
            verificationCheckInGrace: .milliseconds(300)
        )
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
        let flow = makeFlow(stateURL: fixture.stateURL)

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
