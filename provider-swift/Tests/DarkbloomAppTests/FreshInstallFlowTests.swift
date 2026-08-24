import Foundation
import Testing
@testable import DarkbloomApp

@Suite("FreshInstall full onboarding", .serialized)
@MainActor
struct FreshInstallFlowTests {
    @Test("fresh preferences reach completion through only non-interactive CLI argv")
    func liveHappyPath() async throws {
        let harness = try FreshInstallHarness()
        defer { harness.cleanup() }
        let openedURLs = FreshInstallURLRecorder()
        let flow = harness.makeFlow(openedURLs: openedURLs)
        let preferences = harness.preferences()
        let app = AppFlowStore(
            preferences: preferences,
            launchOverride: nil,
            onboardingFlow: flow
        )

        #expect(app.phase == .welcome)
        #expect(!app.hasCompletedNetworkOnboarding)
        #expect(preferences.onboardingDraft == nil)
        #expect(harness.assertHermeticPaths())

        app.startOnboarding()
        #expect(app.phase == .onboarding)

        await flow.runAutomaticWorkForCurrentStep()
        #expect(flow.readinessPhase == .ready)
        #expect(flow.readinessItems.allSatisfy { $0.state == .complete })
        flow.continueToNextStep()
        #expect(flow.step == .account)

        flow.startAccountLink()
        #expect(await freshInstallEventually { flow.accountPhase == .linked })
        #expect(openedURLs.urls == [URL(string: "https://app.darkbloom.test/link")!])
        flow.continueToNextStep()
        #expect(flow.step == .enrollment)

        await flow.beginEnrollment()
        #expect(flow.enrollmentPhase == .systemSettingsOpen)
        #expect(flow.enrollmentProfilePath?.hasPrefix(harness.root.path) == true)

        // The opened-profile path starts one real-evidence poll immediately.
        // Observe that poll before simulating the user's macOS profile action,
        // so argv ordering stays deterministic instead of racing a timer.
        #expect(await freshInstallEventually {
            (try? harness.invocations().filter { $0 == ["doctor", "--json"] }.count) == 2
        })
        try harness.markProfileInstalled()
        await flow.confirmProfileInstallation()
        #expect(flow.enrollmentPhase == .profileDetected)
        flow.cancelPendingOperations()
        flow.continueToNextStep()
        #expect(flow.step == .preparation)

        await flow.runAutomaticWorkForCurrentStep()
        #expect(flow.preparationPhase == .choosingModel)
        #expect(flow.selectedModelID == FreshInstallHarness.modelID)
        flow.startPreparation()
        #expect(await freshInstallEventually { flow.preparationPhase == .ready })
        #expect(flow.preparationProgress == 1)
        #expect(harness.providerEvidence().reportsStarted(modelID: FreshInstallHarness.modelID))
        flow.continueToNextStep()
        #expect(flow.step == .verification)

        let verification = Task { await flow.runAutomaticWorkForCurrentStep() }
        #expect(await freshInstallEventually { flow.verificationPhase == .trustPending })
        try harness.setTrust(status: "verified", level: "hardware")
        await verification.value
        #expect(flow.verificationPhase == .hardwareTrusted)
        flow.continueToNextStep()
        #expect(flow.step == .complete)
        #expect(flow.hasCompletedAllRequiredSteps)

        #expect(app.completeOnboarding(opening: .chat))
        #expect(app.phase == .product)
        #expect(app.hasCompletedNetworkOnboarding)
        #expect(preferences.hasCompletedNetworkOnboarding)
        #expect(preferences.onboardingDraft == nil)

        #expect(try harness.invocations() == [
            ["doctor", "--json"],
            ["login", "--json"],
            ["enroll", "--json"],
            ["doctor", "--json"],
            ["doctor", "--json"],
            ["models", "catalog", "--json", "--include-download-plans"],
            ["models", "list", "--json"],
            ["models", "download", FreshInstallHarness.modelID, "--json"],
            ["start", "--model", FreshInstallHarness.modelID, "--local-endpoint"],
        ])

        let invocations = try harness.invocations()
        #expect(!invocations.contains { $0 == ["start"] })
        #expect(!invocations.contains { $0.contains("--all") })
        #expect(!invocations.contains { $0.first == "local" })
        #expect(!invocations.contains { $0.first == "open" })
        #expect(!FileManager.default.fileExists(
            atPath: harness.configDirectory.appendingPathComponent("provider.toml").path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: harness.home.appendingPathComponent(".darkbloom").path
        ))
    }
}
