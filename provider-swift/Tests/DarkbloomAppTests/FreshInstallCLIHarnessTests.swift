import Foundation
import ProviderCoreFoundation
import Testing
@testable import DarkbloomApp

@Suite("FreshInstall hermetic CLI harness", .serialized)
struct FreshInstallCLIHarnessTests {
    @Test("all onboarding machine contracts stay inside temporary state")
    func allMachineContractsAreHermetic() async throws {
        let harness = try FreshInstallHarness()
        defer { harness.cleanup() }

        #expect(harness.assertHermeticPaths())
        #expect(harness.locator().locate() == harness.executable)
        #expect(!FileManager.default.fileExists(atPath: harness.preferencesFile.path))

        let freshDoctor = try await harness.diagnosticsRunner().runDoctorJSON()
        #expect(freshDoctor.schema == 1)
        #expect(freshDoctor.check(id: "account-link")?.status == "warn")
        #expect(freshDoctor.check(id: "mdm-enrollment")?.status == "warn")

        var accountEvents: [AccountLinkEvent] = []
        for try await event in harness.accountRunner().linkEvents() {
            accountEvents.append(event)
        }
        #expect(accountEvents == [
            .code(
                userCode: "FRESH-001",
                verificationURI: "https://app.darkbloom.test/link",
                expiresIn: 900
            ),
            .linked,
        ])

        let enrollment = try await ProcessEnrollmentCLI(locator: harness.locator()).enroll()
        #expect(enrollment == EnrollmentCLIResponse(
            schema: 1,
            status: .profileOpened,
            serialNumber: "FRESHINSTALL",
            profilePath: harness.root.appendingPathComponent("Darkbloom.mobileconfig").path
        ))

        try harness.markProfileInstalled()
        let enrolledDoctor = try await harness.diagnosticsRunner().runDoctorJSON()
        #expect(enrolledDoctor.reportsLinkedAccount)
        #expect(enrolledDoctor.reportsDarkbloomEnrollment)

        let preparation = OnboardingPreparationService(
            catalog: harness.modelRunner(),
            startCLI: ProcessSetupStartCLI(
                runner: harness.providerRunner(),
                timeout: .seconds(2)
            ),
            availableStorageBytes: { 20 * 1_073_741_824 }
        )
        let plan = try await preparation.fetchPlan()
        #expect(plan.recommendedModelID == FreshInstallHarness.modelID)
        #expect(plan.choices.map(\.id) == [FreshInstallHarness.modelID])
        #expect(plan.choices.first?.isInstalled == false)

        var downloadEvents: [ModelDownloadStreamEvent] = []
        for try await event in preparation.downloadEvents(modelID: FreshInstallHarness.modelID) {
            downloadEvents.append(event)
        }
        #expect(downloadEvents == [
            .progress(file: "model.safetensors", bytes: 1_048_576, total: 1_048_576),
            .verifying,
            .done,
        ])

        try await preparation.startProvider(modelID: FreshInstallHarness.modelID)
        let daemon = try #require(DaemonStateFile.read(from: harness.stateFile))
        #expect(daemon.currentModel == FreshInstallHarness.modelID)
        #expect(daemon.inferenceActive)
        #expect(daemon.trust?.status == "pending")
        let processIdentity = try #require(daemon.processIdentity)
        #expect(processIdentity.pid == daemon.pid)
        #expect(processIdentity.isCurrent())
        #expect(DaemonStateRuntimeTruth.belongsToLiveProcess(daemon))

        let localData = try Data(
            contentsOf: harness.localDirectory.appendingPathComponent("local.json")
        )
        let local = try JSONDecoder().decode(LocalEndpointInfo.self, from: localData)
        #expect(local.baseURL == "http://127.0.0.1:18080/v1")
        #expect(local.pid == daemon.pid)
        #expect(local.processIdentity == daemon.processIdentity)
        #expect(LocalEndpointRuntimeTruth.belongsToLiveProcess(local))

        #expect(try harness.invocations() == [
            ["doctor", "--json"],
            ["login", "--json"],
            ["enroll", "--json"],
            ["doctor", "--json"],
            ["models", "catalog", "--json"],
            ["models", "list", "--json"],
            ["models", "download", FreshInstallHarness.modelID, "--json"],
            ["start", "--model", FreshInstallHarness.modelID, "--local-endpoint"],
        ])

        #expect(!FileManager.default.fileExists(
            atPath: harness.configDirectory.appendingPathComponent("provider.toml").path
        ))
        #expect(!FileManager.default.fileExists(
            atPath: harness.home.appendingPathComponent(".darkbloom").path
        ))
    }
}
