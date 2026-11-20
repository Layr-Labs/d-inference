import Foundation
import DarkbloomClusterProtocol
import DarkbloomClusterSecurity

// CPU fixture configuration only. The shipped owner does not read this file.
struct MemberFixtureConfiguration: Codable, Sendable {
    let startBase64: String
    let clusterID: String
    let configurationSHA256: String
    let modelID: String
    let leaseDirectory: String
    let behavior: String
    var start: ClusterNativeAuthorizationStart {
        get throws {
            guard let data = Data(base64Encoded: startBase64) else { throw MemberFixtureError.invalid }
            return try ClusterNativeAuthorizationStart(encoded: data)
        }
    }
    func identity(epoch: UUID) throws -> ClusterWorkerIdentity {
        let c = try start.common
        return .init(membershipEpoch: epoch, modelID: modelID,
            artifactSHA256: c.artifactSHA256.hex, configurationSHA256: configurationSHA256,
            peers: [.init(id: "fixture-rank-0", buildSHA256: c.nativeRuntimeSHA256.hex),
                    .init(id: "fixture-rank-1", buildSHA256: c.nativeRuntimeSHA256.hex)])
    }
    static let profile = ClusterWorkerProfile(id: "native-key-cpu-fixture", vocabularySize: 256,
        maximumPromptTokens: 8, maximumOutputTokens: 2, maximumChunkTokens: 4, maximumContextTokens: 16)
    static func read(beside executable: URL) throws -> Self {
        let raw = try Data(contentsOf: executable.deletingLastPathComponent().appendingPathComponent("fixture.json"))
        guard raw.count <= 8192 else { throw MemberFixtureError.invalid }
        return try JSONDecoder().decode(Self.self, from: raw)
    }
}
enum MemberFixtureError: Error { case invalid }
extension Data { var hex: String { map { String(format: "%02x", $0) }.joined() } }
