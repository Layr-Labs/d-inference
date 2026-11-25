import DarkbloomClusterProtocol

/// Private qualification entry, never an installed-product model allowlist.
enum Qwen27BQualificationScope {
    static let stageCut = 16
    static let modelID = "registered_qwen38_27b"
    static let profileID = "registered_qwen38_27b_greedy_generation_v1"
    static let artifactSHA256 = "bbd0e0adcfe74e095073fefd0b9e116e4311d606ad9989cf81f8175e8ac18463"
    static let configurationSHA256 = "4691da94a1b4ef415aad112ec46abebd33f8a41ad07380e486c0526eb945c1ff"

    static func validate(_ ready: ClusterWorkerReady) throws {
        guard ready.identity.modelID == modelID,
              ready.identity.artifactSHA256 == artifactSHA256,
              ready.identity.configurationSHA256 == configurationSHA256,
              ready.profile == ClusterWorkerProfile(id: profileID, vocabularySize: 248_320,
                maximumPromptTokens: 8192, maximumOutputTokens: 128,
                maximumChunkTokens: 512, maximumContextTokens: 8320) else {
            throw ClusterWorkerProtocolError.invalid("Wrong private 27B qualification identity/profile")
        }
    }
}
