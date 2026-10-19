import Foundation
import DarkbloomClusterProtocol

/// Private wire mirror of the worker calibration contract. Keep CPU provider
/// authorization independent of the GPU runtime target. Never a serving receipt.
enum GLM5NextCalibrationDocument {
    static let domain = Data("darkbloom/glm-worker-calibration/v1\0".utf8)
    static let modelID = "qualification_glm5_next"
    struct Body: Codable {
        let selection: Payload
        let authorization: Authorization
        let binding: GLM5NextCalibrationBinding
    }
    struct SignedDocument: Codable { let payload: Data; let signature: Data }
    struct File: Codable { let bytes: Int; let sha256: String }
    struct Payload: Codable {
        let version: Int
        let epoch: UUID
        let rank: Int
        let expiresUnixSeconds: Int64
        let repository: String
        let revision: String
        let files: [String: File]
        let artifactSHA256: String
        let cut: Int
        let profileID: String
        let maximumPromptTokens: Int
        let maximumChunkTokens: Int
        let maximumOutputTokens: Int
        let maximumContextTokens: Int
        let policy: String
        let storage: String
        let loadCapacityBytes: Int
        let requestCapacityBytes: Int
        let hostAllocationQuantum: Int
        let hostAllocationOverhead: Int
        let environment: Environment
        let workspaceEvidence: Data
    }
    struct Environment: Codable, Equatable {
        let binarySHA256: String
        let metallibSHA256: String
        let backend: String
        let allocator: String
        let os: String
        let deviceRegistryID: UInt64
        let deviceName: String
        let architecture: String
        let maximumBufferBytes: Int
        let recommendedWorkingSetBytes: UInt64
        let memoryBytes: Int
        let variableSHA256: [String: String]
    }
    struct Authorization: Codable, Equatable {
        let requestID: UUID
        let nativeHardCapBytes: Int
        let hostBudgetBytes: Int
        let osHeadroomBytes: Int
        let workspaceNativeAllowanceBytes: Int
        let workspaceHostAllowanceBytes: Int
        let promptTokenIDs: [Int]
        let outputCount: Int
        let chunkSize: Int

        init(requestID: UUID, nativeHardCapBytes: Int, hostBudgetBytes: Int, osHeadroomBytes: Int,
                    workspaceNativeAllowanceBytes: Int, workspaceHostAllowanceBytes: Int,
                    promptTokenIDs: [Int], outputCount: Int, chunkSize: Int) throws {
            self.requestID = requestID; self.nativeHardCapBytes = nativeHardCapBytes
            self.hostBudgetBytes = hostBudgetBytes; self.osHeadroomBytes = osHeadroomBytes
            self.workspaceNativeAllowanceBytes = workspaceNativeAllowanceBytes
            self.workspaceHostAllowanceBytes = workspaceHostAllowanceBytes
            self.promptTokenIDs = promptTokenIDs; self.outputCount = outputCount; self.chunkSize = chunkSize
            try validate()
        }
        func validate() throws {
            guard nativeHardCapBytes > 0, hostBudgetBytes > 0, osHeadroomBytes > 0,
                  !nativeHardCapBytes.addingReportingOverflow(hostBudgetBytes).overflow,
                  workspaceNativeAllowanceBytes > 0,
                  workspaceHostAllowanceBytes > 0,
                  workspaceNativeAllowanceBytes < nativeHardCapBytes,
                  workspaceHostAllowanceBytes < hostBudgetBytes,
                  !promptTokenIDs.isEmpty, promptTokenIDs.count <= 2048,
                  promptTokenIDs.allSatisfy({ $0 >= 0 }), (1...16).contains(outputCount),
                  (1...2048).contains(chunkSize), chunkSize <= promptTokenIDs.count else {
                throw GLM5NextCalibrationDocument.invalid("Calibration requires explicit bounded allowances and one small cold text request")
            }
        }
    }


    static func invalid(_ message: String) -> ClusterConfigurationError {
        .invalid("GLM calibration: " + message)
    }
    static func hashSyntax(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    static func validate(_ body: Body, identity: ClusterWorkerIdentity, rank: Int, now: Int64, expectedVocabularySize: Int) throws {
        let p = body.selection, a = body.authorization
        try a.validate()
        try body.binding.validate(profileID: p.profileID, vocabularySize: expectedVocabularySize,
            prompt: p.maximumPromptTokens, output: p.maximumOutputTokens,
            chunk: p.maximumChunkTokens, context: p.maximumContextTokens)
        guard a.promptTokenIDs.allSatisfy({ $0 < expectedVocabularySize }) else {
            throw invalid("Prompt token exceeds the pinned configuration vocabulary")
        }
        try requirePinnedSelection(repository: p.repository, revision: p.revision,
            artifactSHA256: p.artifactSHA256, files: p.files)
        guard (0...1).contains(rank), identity.peers.count == 2,
              identity.modelID == modelID, p.version == 1, p.rank == rank,
              p.epoch == identity.membershipEpoch, now >= 0, p.expiresUnixSeconds > now,
              p.expiresUnixSeconds - now <= 3600,
              p.artifactSHA256 == identity.artifactSHA256,
              p.files["config.json"]?.sha256 == identity.configurationSHA256,
              p.environment.binarySHA256 == identity.peers[rank].buildSHA256,
              (1..<45).contains(p.cut), !p.profileID.isEmpty,
              p.storage == "nvfp4Hybrid", p.policy == "serving_v1", p.workspaceEvidence.isEmpty,
              p.loadCapacityBytes > 0, p.requestCapacityBytes > 0,
              p.requestCapacityBytes <= p.loadCapacityBytes,
              p.loadCapacityBytes <= a.nativeHardCapBytes + a.hostBudgetBytes,
              a.nativeHardCapBytes + a.hostBudgetBytes <= p.environment.memoryBytes,
              a.osHeadroomBytes < p.environment.memoryBytes - a.nativeHardCapBytes - a.hostBudgetBytes,
              (1...(1 << 30)).contains(p.hostAllocationQuantum),
              (0...(1 << 30)).contains(p.hostAllocationOverhead),
              (1...2048).contains(p.maximumPromptTokens),
              (1...p.maximumPromptTokens).contains(p.maximumChunkTokens),
              (1...16).contains(p.maximumOutputTokens),
              p.maximumContextTokens >= p.maximumPromptTokens + p.maximumOutputTokens,
              p.maximumContextTokens <= 2064,
              a.promptTokenIDs.count <= p.maximumPromptTokens, a.outputCount <= p.maximumOutputTokens,
              a.chunkSize <= p.maximumChunkTokens,
              p.environment.backend == "jaccl", p.environment.allocator == "disableFreedBufferCache",
              hashSyntax(p.environment.binarySHA256), hashSyntax(p.environment.metallibSHA256),
              !p.environment.os.isEmpty, !p.environment.deviceName.isEmpty,
              !p.environment.architecture.isEmpty, p.environment.maximumBufferBytes > 0,
              p.environment.recommendedWorkingSetBytes > 0,
              p.environment.variableSHA256.allSatisfy({
                  ($0.key.hasPrefix("MLX_") || $0.key.hasPrefix("DARKBLOOM_")) && hashSyntax($0.value)
              }),
              !p.files.isEmpty, p.files.allSatisfy({ entry in
                  let parts = entry.key.split(separator: "/", omittingEmptySubsequences: false)
                  return parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
                      && !entry.key.utf8.contains(where: { $0 < 32 || $0 == 127 })
                      && entry.value.bytes > 0 && hashSyntax(entry.value.sha256)
              }) else { throw invalid("Identity, scope, environment or explicit capacity differs") }
    }

    static func requirePinnedSelection(repository: String, revision: String,
                                       artifactSHA256: String, files: [String: File]) throws {
        guard repository == "EigenLabs/GLM-5.3-Flash-MLX-NVFP4-mtp",
              revision == "8841c52a1e8400bd7d3e7e631c916a6c4e6757b0",
              artifactSHA256 == "3aae613ff188bb0f72e880774a84e4d8e9943ab20c929d8a302af9c57b97d5ac",
              files["config.json"]?.sha256 == "949a3db19177feacc434abe791f0d73f24f34ad577334d8773ac5a0afbfd2e8b",
              files["model.safetensors.index.json"]?.sha256 == "b6cdec53a012ec4a8b383d37224f5955d463ec244d80b43d24fac72aa4c07b47" else {
            throw invalid("Selection differs from pinned EigenLabs artifact")
        }
    }
}
