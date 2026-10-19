import Foundation
import Testing
import DarkbloomClusterProtocol
@testable import ProviderCore

/// UNRUN CPU policy/metadata tests. Existing fixture describes actual pinned
/// config/manifest; no model, layout-tool child, native Ready or image execution.
struct MiMoImageOnboardingSelectionTests {
    @Test func bothMetadataProducersReceiveTheSameClosedProfileAndDefaultArgumentsStayEmpty() {
        let directory = URL(fileURLWithPath: "/fixture/actual-model"), workerHash = String(repeating: "a", count: 64)
        let legacy = ClusterMiMoOnboardingSelection.probeArguments(directory: directory, expectedWorkerSHA256: workerHash, qualifying: false)
        #expect(legacy.layout == ["layout", "--model-dir", directory.path, "--json"])
        #expect(legacy.capability == ["--describe-runtime", "--config", directory.appendingPathComponent("config.json").path,
            "--manifest", directory.appendingPathComponent("manifest.json").path, "--expected-executable-sha256", workerHash])
        let image = ClusterMiMoOnboardingSelection.probeArguments(directory: directory, expectedWorkerSHA256: workerHash, qualifying: true)
        let profile = ["--runtime-profile", ClusterMiMoImageCandidate.profileID]
        #expect(image.layout == legacy.layout + profile)
        #expect(image.capability == legacy.capability + profile)
    }
    @Test func privateSelectionRequiresTheExactArtifactRatherThanATitleOrAnotherModel() {
        let model = ClusterSetupLocalModel(folder: "installed", modelID: ClusterOnboardingRequest.privateMiMoModelID,
            version: "2026-09-28-r1", artifactSHA256: ClusterMiMoImageCandidate.artifactSHA256, totalBytes: 1)
        #expect(ClusterMiMoOnboardingSelection.accepts(model, qualifying: true))
        var wrongArtifact = model; wrongArtifact.artifactSHA256 = String(repeating: "a", count: 64)
        var foreign = model; foreign.modelID = "glm-5-next"
        #expect(!ClusterMiMoOnboardingSelection.accepts(wrongArtifact, qualifying: true))
        #expect(!ClusterMiMoOnboardingSelection.accepts(foreign, qualifying: true))
        #expect(ClusterMiMoOnboardingSelection.accepts(wrongArtifact, qualifying: false))
        #expect(ClusterMiMoOnboardingSelection.accepts(foreign, qualifying: false))
    }
    @Test func actualPinnedMetadataMustDescribeImageAndCannotFallBackToText() throws {
        let fixture = MiMoInstalledImagePolicyTests()
        let image = try fixture.capability(image: true), text = try fixture.capability(image: false)
        try ClusterMiMoOnboardingSelection.requireCandidate(image, qualifying: true)
        #expect(throws: (any Error).self) { try ClusterMiMoOnboardingSelection.requireCandidate(text, qualifying: true) }
        try ClusterMiMoOnboardingSelection.requireCandidate(text, qualifying: false)
        // Selection does not grant public traffic or waive the installed encryption gates.
        #expect(throws: (any Error).self) { try ClusterMiMoPrivateImagePolicy.requireCoordinatorEligible(image) }
        #expect(throws: (any Error).self) {
            try ClusterMiMoPrivateImagePolicy.launchArguments(image, keyed: false, startupGuard: true)
        }
    }
    @Test func inputAndCurrentLeaderChecksAreClosedAndOrdinaryRequestsRemainUnrestricted() {
        let valid = ClusterOnboardingRequest(scope: .localOnly(bind: "127.0.0.1"), model: ClusterOnboardingRequest.privateMiMoModelID,
            privateMiMoImageQualification: true)
        #expect(valid.privateQualificationRefusal(role: .leader) == nil)
        #expect(valid.privateQualificationRefusal(role: .member) != nil)
        #expect(valid.privateQualificationRefusal(role: nil) != nil)
        var publicRequest = valid; publicRequest.scope = .publicServing
        #expect(publicRequest.privateQualificationRefusal(role: .leader) != nil)
        #expect(ClusterOnboardingRequest().privateQualificationRefusal(role: .member) == nil)
        #expect(ClusterOnboardingRequest().privateQualificationRefusal(role: nil) == nil)
    }
}
