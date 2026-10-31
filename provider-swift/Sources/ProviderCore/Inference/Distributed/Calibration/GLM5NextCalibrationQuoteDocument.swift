import Foundation
import DarkbloomClusterProtocol

/// CPU-only mirror of the private worker's quote protocol. It carries explicit
/// allowances, never guessed final capacities or measured workspace evidence.
enum GLM5NextCalibrationQuoteDocument {
    typealias D = GLM5NextCalibrationDocument
    static let domain = Data("darkbloom/glm-calibration-quote/v1\0".utf8)
    struct Selection: Codable {
        let version: Int
        let epoch: UUID
        let rank: Int
        let expiresUnixSeconds: Int64
        let repository: String
        let revision: String
        let files: [String: D.File]
        let artifactSHA256: String
        let cut: Int
        let profileID: String
        let maximumPromptTokens: Int
        let maximumChunkTokens: Int
        let maximumOutputTokens: Int
        let maximumContextTokens: Int
        let policy: String
        let storage: String
        let mode: String
        let hostAllocationQuantum: Int
        let hostAllocationOverhead: Int
        let environment: D.Environment
    }
    struct Request: Codable {
        let quoteRequestID: UUID
        let peerIdentitySHA256: String
        let appSHA256: String
        let selection: Selection
        let authorization: D.Authorization
    }
    struct Response: Codable {
        let version: Int
        let purpose: String
        let quoteRequestID: UUID
        let quoteRequestSHA256: String
        let rank: Int
        let cut: Int
        let repository: String
        let revision: String
        let artifactSHA256: String
        let rawConfigurationFileSHA256: String
        let normalizedConfigurationSHA256: String
        let descriptorSHA256: String
        let inventorySHA256: String
        let numericalPolicySHA256: String
        let executionEnvironmentSHA256: String
        let nativeBytes: Int
        let hostBytes: Int
        let loadCapacityBytes: Int
        let requestCapacityBytes: Int
        let qualifiesMaximumEnvelope: Bool
        let payloadVerified: Bool
        let binding: GLM5NextCalibrationBinding
    }
    static func canonical<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    static func validate(_ request: Request, identity: ClusterWorkerIdentity, rank: Int, now: Int64,
                         appSHA256: String, peerIdentitySHA256: String) throws {
        let p = request.selection, a = request.authorization, e = p.environment
        try a.validate()
        try D.requirePinnedSelection(repository: p.repository, revision: p.revision,
            artifactSHA256: p.artifactSHA256, files: p.files)
        guard (0...1).contains(rank), identity.peers.count == 2, identity.modelID == D.modelID,
              p.version == 1, p.epoch == identity.membershipEpoch, p.rank == rank,
              p.artifactSHA256 == identity.artifactSHA256,
              p.files["config.json"]?.sha256 == identity.configurationSHA256,
              e.binarySHA256 == identity.peers[rank].buildSHA256,
              now >= 0, p.expiresUnixSeconds > now, p.expiresUnixSeconds - now <= 3600,
              p.mode == "coldTextBatch1", p.policy == "serving_v1", p.storage == "nvfp4Hybrid",
              (1..<45).contains(p.cut), !p.profileID.isEmpty, p.profileID.utf8.count <= 128,
              (1...2048).contains(p.maximumPromptTokens),
              (1...p.maximumPromptTokens).contains(p.maximumChunkTokens),
              (1...16).contains(p.maximumOutputTokens),
              p.maximumContextTokens >= p.maximumPromptTokens + p.maximumOutputTokens,
              p.maximumContextTokens <= 2064,
              a.promptTokenIDs.count <= p.maximumPromptTokens, a.chunkSize <= p.maximumChunkTokens,
              a.outputCount <= p.maximumOutputTokens,
              (1...(1 << 30)).contains(p.hostAllocationQuantum),
              (0...(1 << 30)).contains(p.hostAllocationOverhead),
              a.nativeHardCapBytes + a.hostBudgetBytes <= e.memoryBytes,
              a.osHeadroomBytes < e.memoryBytes - a.nativeHardCapBytes - a.hostBudgetBytes,
              e.backend == "jaccl", e.allocator == "disableFreedBufferCache",
              D.hashSyntax(e.binarySHA256), D.hashSyntax(e.metallibSHA256),
              D.hashSyntax(appSHA256), request.appSHA256 == appSHA256,
              D.hashSyntax(peerIdentitySHA256), request.peerIdentitySHA256 == peerIdentitySHA256,
              e.variableSHA256[GLM5NextCalibrationLaunch.appIdentityVariable] == GLM5NextCalibrationLaunch.digest(appSHA256),
              e.variableSHA256[GLM5NextCalibrationLaunch.peerIdentityVariable] == GLM5NextCalibrationLaunch.digest(peerIdentitySHA256),
              !e.os.isEmpty, !e.deviceName.isEmpty, !e.architecture.isEmpty,
              e.maximumBufferBytes > 0, e.recommendedWorkingSetBytes > 0,
              e.variableSHA256.count <= 128,
              e.variableSHA256.allSatisfy({
                  ($0.key.hasPrefix("MLX_") || $0.key.hasPrefix("DARKBLOOM_")) && D.hashSyntax($0.value)
              }),
              (3...258).contains(p.files.count), p.files.allSatisfy({ name, file in
                  !name.isEmpty && name.utf8.count <= 255 && !name.contains("/") && !name.contains("\\")
                      && name != "." && name != ".." && !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
                      && file.bytes > 0 && D.hashSyntax(file.sha256)
              }) else { throw D.invalid("Quotation differs from authenticated identity, scope or allowances") }
    }
}
