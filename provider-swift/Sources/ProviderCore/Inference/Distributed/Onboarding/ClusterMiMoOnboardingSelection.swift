import Foundation
import DarkbloomClusterProtocol

/// Selects one closed private metadata profile; it grants no LOAD, native
/// memory waiver, encrypted readiness or coordinator/public serving authority.
enum ClusterMiMoOnboardingSelection {
    static func probeArguments(directory: URL, expectedWorkerSHA256: String, qualifying: Bool)
        -> (layout: [String], capability: [String]) {
        let profile = qualifying ? [ClusterMiMoImageCandidate.runtimeProfileArgument, ClusterMiMoImageCandidate.profileID] : []
        return (["layout", "--model-dir", directory.path, "--json"] + profile,
            ["--describe-runtime", "--config", directory.appendingPathComponent("config.json").path,
             "--manifest", directory.appendingPathComponent("manifest.json").path,
             "--expected-executable-sha256", expectedWorkerSHA256] + profile)
    }

    static func accepts(_ model: ClusterSetupLocalModel, qualifying: Bool) -> Bool {
        !qualifying || (model.modelID == ClusterOnboardingRequest.privateMiMoModelID
            && model.artifactSHA256 == ClusterMiMoImageCandidate.artifactSHA256)
    }

    static func requireCandidate(_ capability: ClusterRuntimeCapability, qualifying: Bool) throws {
        guard qualifying else { return }
        guard capability.media != nil else {
            throw ClusterConfigurationError.invalid("The worker did not describe the requested private MiMo image candidate; text fallback is refused")
        }
        try ClusterMiMoImageCandidate.validateSource(profileID: capability.profile.id, modelID: capability.runtimeModelID,
            artifact: capability.artifactSHA256, configuration: capability.configurationSHA256,
            manifest: capability.manifestSHA256)
    }
}
