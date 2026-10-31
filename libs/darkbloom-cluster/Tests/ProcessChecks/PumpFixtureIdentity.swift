import Foundation
import DarkbloomClusterProtocol

let fixtureIdentity = ClusterWorkerIdentity(membershipEpoch: UUID(uuidString: "aaaaaaaa-1111-2222-3333-bbbbbbbbbbbb")!,
    modelID: "fixture-model", artifactSHA256: String(repeating: "a", count: 64), configurationSHA256: String(repeating: "b", count: 64),
    peers: [.init(id: "first", buildSHA256: String(repeating: "c", count: 64)), .init(id: "second", buildSHA256: String(repeating: "d", count: 64))])
let fixtureProfile = ClusterWorkerProfile(id: "fixture-greedy", vocabularySize: 512,
    maximumPromptTokens: 16, maximumOutputTokens: 128, maximumChunkTokens: 8, maximumContextTokens: 144)
let fixturePlan = String(repeating: "e", count: 64)

