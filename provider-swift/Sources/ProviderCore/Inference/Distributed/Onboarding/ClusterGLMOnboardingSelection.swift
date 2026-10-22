import Foundation
import DarkbloomClusterProtocol

/// GLM's explicit local selection. Ordinary and MiMo discovery keep their
/// existing paths; no artifact is downloaded or admitted by this selection.
enum ClusterGLMOnboardingSelection {
    static func accepts(_ model: ClusterSetupLocalModel) -> Bool {
        model.modelID == ClusterOnboardingRequest.privateGLMModelID
            && model.artifactSHA256 == ClusterGLMImageCandidate.artifactSHA256
    }
    static func probeArguments(directory: URL, expectedWorkerSHA256: String) -> (layout: [String], capability: [String]) {
        let profile = ["--runtime-profile", ClusterGLMImageCandidate.profileID]
        return (["layout", "--model-dir", directory.path, "--json"] + profile,
            ["--describe-runtime", "--config", directory.appendingPathComponent("config.json").path,
             "--manifest", directory.appendingPathComponent("manifest.json").path,
             "--expected-executable-sha256", expectedWorkerSHA256] + profile)
    }
    static func requireCandidate(_ capability: ClusterRuntimeCapability) throws {
        guard capability.glmImages != nil, capability.media == nil,
              capability.adapterID == ClusterRuntimeAdapter.glm5NextLayerStage.rawValue else {
            throw ClusterConfigurationError.invalid("The worker did not describe the selected GLM image candidate; text fallback refused")
        }
        try ClusterGLMImageCandidate.validateSource(profileID: capability.profile.id, modelID: capability.runtimeModelID,
            artifact: capability.artifactSHA256, configuration: capability.configurationSHA256, manifest: capability.manifestSHA256)
    }
}
