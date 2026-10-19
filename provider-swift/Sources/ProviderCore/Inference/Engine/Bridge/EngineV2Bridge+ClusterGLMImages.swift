import Foundation
import DarkbloomClusterProtocol

extension EngineV2Bridge {
    func clusterGLMImageIngress() throws -> (ingress: DistributedGLMImageIngress, maximumPrompt: Int, defaultOutput: Int)? {
        guard let bytes = clusterGLMImageConfiguration else { return nil }
        guard canSubmitWithNativeOwner(), let distributed = ownedEngine as? DistributedCBv2Engine,
              distributed.identity.modelID == "registered_glm53_flash",
              distributed.profile.id == ClusterStillImages.glmProfileID,
              distributed.owner.readiness()?.profileID == distributed.profile.id else {
            throw DistributedEngineError.refused(.mediaUnsupported)
        }
        return (try .init(configuration: bytes, expectedSHA256: distributed.identity.configurationSHA256),
            distributed.profile.maxPromptTokens, defaultMaxTokens)
    }
}
