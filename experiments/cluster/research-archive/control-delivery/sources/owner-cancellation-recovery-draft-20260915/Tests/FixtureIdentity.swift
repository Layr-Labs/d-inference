import Foundation
import DarkbloomClusterProtocol

func fixtureIdentity(_ epoch: UUID) -> ClusterWorkerIdentity {
    .init(membershipEpoch: epoch, modelID: "fixture-model", artifactSHA256: String(repeating: "a", count: 64),
        configurationSHA256: String(repeating: "b", count: 64),
        peers: [.init(id: "first", buildSHA256: String(repeating: "c", count: 64)),
                .init(id: "second", buildSHA256: String(repeating: "d", count: 64))])
}
let fixtureProfile = ClusterWorkerProfile(id: "fixture-greedy", vocabularySize: 512,
    maximumPromptTokens: 8192, maximumOutputTokens: 128, maximumChunkTokens: 512, maximumContextTokens: 8320)
let fixturePlan = String(repeating: "e", count: 64)
