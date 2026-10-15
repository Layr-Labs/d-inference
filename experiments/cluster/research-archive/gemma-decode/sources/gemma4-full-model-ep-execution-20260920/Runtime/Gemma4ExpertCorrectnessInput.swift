import Foundation
import MLX

struct Gemma4ExpertCorrectnessJob: Codable {
    let schema: String
    let mode: String
    let modelDirectory: String, metadataDirectory: String, promptFile: String
    let promptFileSHA256: String, outputDirectory: String
    let requestID: String, membershipEpoch: String
    let buildIdentitySHA256: String
    let rankBuildSHA256: [String]
    let globalExpertIDsByRank: [[Int]]
    let timeoutSeconds: Int
    var rank: Int? { mode == "expert0" ? 0 : mode == "expert1" ? 1 : nil }

    func shortJob() -> Gemma4ShortCheckJob {
        .init(schema: "gemma4_short_native_check_v1", mode: "full",
            modelDirectory: modelDirectory, metadataDirectory: metadataDirectory,
            promptFile: promptFile, promptFileSHA256: promptFileSHA256, outputDirectory: outputDirectory,
            requestID: requestID, membershipEpoch: membershipEpoch,
            buildIdentitySHA256: buildIdentitySHA256, residualDType: "bfloat16", timeoutSeconds: timeoutSeconds)
    }
    func validate() throws {
        try shortJob().validate()
        guard schema == "gemma4_full_expert_correctness_job_v1", ["full","expert0","expert1"].contains(mode),
              rankBuildSHA256.count == 2, rankBuildSHA256.allSatisfy(qwenStageWireIsSHA256),
              rank.map({ rankBuildSHA256[$0] == buildIdentitySHA256 }) ?? true else {
            throw ProbeError("Gemma EP job mode/build scope differs")
        }
        _ = try Gemma4ExpertPartition(rank: 0, globalIDsByRank: globalExpertIDsByRank)
        // Generic complete/disjoint IDs, always prospective and subject to the
        // unchanged actual live ledger. No map is endorsed by count alone.
    }
    static func read(_ url: URL) throws -> Self {
        let bytes = try BoundedProbeInput.data(url, maximumBytes: 16_384)
        try validateWorkerJSON(bytes)
        let value = try JSONDecoder().decode(Self.self, from: bytes)
        try value.validate()
        try QwenLayerStageGenerationWireJSON.requireExact(QwenLayerStageGenerationWireJSON.object(bytes), value)
        return value
    }
}

struct Gemma4ExpertCorrectnessInput {
    let job: Gemma4ExpertCorrectnessJob
    let original: Gemma4ShortCheckInput
    let partition: Gemma4ExpertPartition?
    let ownershipSHA256: String
    let scopeSHA256: String
    var artifact: Gemma4ArtifactMetadata { original.artifact }
    var plan: Gemma4LayerStagePlan { original.plan }
    var request: QwenLayerStageGenerationRequest { original.request }
    var target: Gemma4ForwardTarget { partition.map(Gemma4ForwardTarget.expertParallel) ?? .fullReference }
    var assignmentLimit: Int { request.chunkSize * 8 }
    var payloadByteLimit: Int { assignmentLimit * 2816 * 2 }

    init(job: Gemma4ExpertCorrectnessJob) throws {
        try job.validate()
        self.job = job
        original = try .init(job: job.shortJob())
        partition = try job.rank.map { try .init(rank: $0, globalIDsByRank: job.globalExpertIDsByRank) }
        ownershipSHA256 = sha256(try canonicalJSONData(job.globalExpertIDsByRank))
        scopeSHA256 = sha256(Data((["gemma4-full-expert-correctness-v1", job.membershipEpoch,
            original.request.fingerprint, original.plan.fingerprint, job.promptFileSHA256,
            Gemma4ArtifactMetadata.artifactAggregateSHA256, Gemma4ArtifactMetadata.configurationSHA256,
            ownershipSHA256] + job.rankBuildSHA256).joined(separator: "|").utf8))
    }
    func binding(purpose: Gemma4ExpertInvocationBinding.Purpose) -> Gemma4ExpertInvocationBinding {
        .init(purpose: purpose, requestID: request.requestID, membershipEpoch: UUID(uuidString: job.membershipEpoch)!,
            requestSHA256: request.fingerprint, artifactSHA256: Gemma4ArtifactMetadata.artifactAggregateSHA256,
            configurationSHA256: Gemma4ArtifactMetadata.configurationSHA256,
            rankBuildSHA256: job.rankBuildSHA256, ownershipSHA256: ownershipSHA256)
    }
    func description() throws -> Gemma4ExpertCorrectnessDescription {
        let targets: [(String,Gemma4ForwardTarget)] = [("full",.fullReference)] + (try (0..<2).map { rank in
            ("expert\(rank)", .expertParallel(try .init(rank: rank, globalIDsByRank: job.globalExpertIDsByRank)))
        })
        let selected = try targets.map { name,target -> Gemma4ShortDescription.Target in
            let values = try Gemma4ForwardSelection.make(plan: plan, target: target)
            let layout = values.map { "\($0.localName):\($0.loadedDType):\($0.selectedShape)" }.sorted().joined(separator:"\n")
            return .init(name: name, parameterLayoutSHA256: sha256(Data(layout.utf8)), selectedTensorCount: values.count,
                selectedBytes: try QwenLongPrefillCheckedBytes.sum(values.map(\.selectedByteCount)), globalLayerIndices: Array(0..<30))
        }
        return .init(scopeSHA256: scopeSHA256, original: try original.description(),
            globalExpertIDsByRank: job.globalExpertIDsByRank, ownershipSHA256: ownershipSHA256,
            rankBuildSHA256: job.rankBuildSHA256, targets: selected, assignmentLimit: assignmentLimit,
            payloadByteLimit: payloadByteLimit, sharedQualificationMaximumAssignments: ExpertAxisQualificationLimits.maximumAssignments)
    }
}

struct Gemma4ExpertCorrectnessDescription: Encodable {
    let schema = "gemma4_full_expert_expected_v1"
    let scopeSHA256: String
    let original: Gemma4ShortDescription
    let globalExpertIDsByRank: [[Int]]
    let ownershipSHA256: String
    let rankBuildSHA256: [String]
    let targets: [Gemma4ShortDescription.Target]
    let assignmentLimit: Int, payloadByteLimit: Int, sharedQualificationMaximumAssignments: Int
    let replicatedFullStatePerRank = true
    let metadataOnly = true, runtimeExecutionAuthorized = false
    let expertNumericalQualificationEstablished = false
}
