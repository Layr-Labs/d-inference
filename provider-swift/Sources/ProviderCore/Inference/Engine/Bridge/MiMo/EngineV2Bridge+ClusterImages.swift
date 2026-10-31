import Foundation
import DarkbloomClusterProtocol

extension EngineV2Bridge {
    func draftMiMoImageIngress() throws -> (ingress:DistributedMiMoImageIngress,maximumPrompt:Int,defaultOutput:Int)? {
        guard let bytes = draftMiMoImageConfiguration else { return nil }
        guard canSubmitWithNativeOwner(),let distributed = ownedEngine as? DistributedCBv2Engine,
              distributed.identity.modelID == "registered_mimo_v26_flash_mopd",
              distributed.identity.artifactSHA256 == "2334547d8acc9898ad4a74570ce44d2b12390bbac8d4bc52c092eb5ad5cfe034",
              distributed.profile.id == "registered_mimo_v26_flash_mopd_greedy_generation_v1" + ClusterMiMoImages.profileSuffix,
              distributed.owner.readiness()?.profileID == distributed.profile.id else {
            throw DistributedEngineError.refused(.mediaUnsupported)
        }
        return (try .init(configuration:bytes,expectedSHA256:distributed.identity.configurationSHA256),
            distributed.profile.maxPromptTokens,defaultMaxTokens)
    }
}
