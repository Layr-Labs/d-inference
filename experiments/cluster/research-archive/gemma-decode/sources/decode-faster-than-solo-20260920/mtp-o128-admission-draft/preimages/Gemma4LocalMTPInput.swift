import Foundation

/// An explicit experiment wrapper around an unchanged, hash-bound ordinary job.
/// Its own scope/flags are authoritative for MTP and evidence, never mtp=false
/// in the retained ordinary input identity. No environment-selected assistant.
struct Gemma4LocalMTPJob: Codable {
    let schema: String
    let benchmarkJob: String, benchmarkJobSHA256: String
    let assistantModelDirectory: String, assistantMetadataDirectory: String
    let maximumDraftTokens: Int
    let captureEvidence: Bool

    func validate() throws {
        guard schema == "gemma4_local_mtp_cohort_job_v1", (1...2).contains(maximumDraftTokens),
              qwenStageWireIsSHA256(benchmarkJobSHA256),
              [benchmarkJob, assistantModelDirectory, assistantMetadataDirectory].allSatisfy({
                  $0.hasPrefix("/") && $0.utf8.count <= 2048 && !$0.contains("\0")
                    && URL(fileURLWithPath: $0).standardizedFileURL.path == $0
              }) else { throw ProbeError("Local MTP job identity, paths or admitted depth differs") }
    }
}

struct Gemma4LocalMTPInput {
    let job: Gemma4LocalMTPJob
    let benchmark: Gemma4BenchmarkInput
    let assistant: Gemma4AssistantArtifact
    let qualifyConditioning: Bool
    let denseProjectionEnabled: Bool
    let headPolicy: Gemma4MTPDenseProjection.HeadPolicy
    let targetProjectionPolicy: String?
    let scopeSHA256: String

    init(url: URL, qualifyConditioning: Bool, denseProjectionEnabled: Bool = false,
         headPolicy: Gemma4MTPDenseProjection.HeadPolicy = .serialM1) throws {
        guard denseProjectionEnabled || headPolicy == .serialM1 else {
            throw ProbeError("Packed target head requires the explicit dense projection scope")
        }
        let bytes = try BoundedProbeInput.data(url, maximumBytes: 16_384)
        try validateWorkerJSON(bytes)
        let job = try JSONDecoder().decode(Gemma4LocalMTPJob.self, from: bytes)
        try job.validate()
        try QwenLayerStageGenerationWireJSON.requireExact(QwenLayerStageGenerationWireJSON.object(bytes), job)
        let original = try BoundedProbeInput.data(URL(fileURLWithPath: job.benchmarkJob), maximumBytes: 16_384)
        guard sha256(original) == job.benchmarkJobSHA256 else { throw ProbeError("Local MTP ordinary job changed") }
        try validateWorkerJSON(original)
        let ordinary = try JSONDecoder().decode(Gemma4BenchmarkJob.self, from: original)
        try ordinary.validate()
        try QwenLayerStageGenerationWireJSON.requireExact(QwenLayerStageGenerationWireJSON.object(original), ordinary)
        guard ordinary.mode == "full", ordinary.rank == nil, ordinary.prefill == .serial,
              !ordinary.captureEvidence, ordinary.chunkSize == 64, ordinary.outputCount == 16,
              [128, 4096].contains(ordinary.promptCount), ordinary.cut == 7,
              ordinary.residualDType == "bfloat16",
              ordinary.modelDirectory != job.assistantModelDirectory,
              ordinary.outputDirectory != job.assistantModelDirectory,
              ordinary.outputDirectory != job.assistantMetadataDirectory else {
            throw ProbeError("Local MTP requires the pinned full P128/P4096 C64 O16 cut7 BF16 workload")
        }
        let benchmark = try Gemma4BenchmarkInput(job: ordinary)
        let directory = URL(fileURLWithPath: job.assistantMetadataDirectory, isDirectory: true)
        func metadata(_ name: String, bound: Int) throws -> Data {
            try BoundedProbeInput.data(directory.appendingPathComponent(name), maximumBytes: bound)
        }
        assistant = try .init(configuration: metadata("config.json", bound: 4096),
            manifest: metadata("manifest.json", bound: 16_384),
            header: metadata("model.safetensors.header.json", bound: 16_384))
        self.job = job; self.benchmark = benchmark; self.qualifyConditioning = qualifyConditioning
        self.denseProjectionEnabled = denseProjectionEnabled
        self.headPolicy = headPolicy
        let projectionPolicy = denseProjectionEnabled
            ? (headPolicy == .serialM1 ? Gemma4MTPDenseProjection.policy : Gemma4MTPDenseProjection.packedHeadPolicy) : nil
        self.targetProjectionPolicy = projectionPolicy
        scopeSHA256 = sha256(Data((["gemma4-local-mtp-cohort-v1", sha256(bytes), job.benchmarkJobSHA256,
            benchmark.scopeSHA256, Gemma4AssistantArtifact.aggregateSHA256, assistant.parameterLayoutSHA256,
            "maximumDraftTokens=\(job.maximumDraftTokens)", "captureEvidence=\(job.captureEvidence)",
            "qualifyConditioning=\(qualifyConditioning)", "mtp=true", "remote=false"]
            + benchmark.requests.map(\.fingerprint)
            + (projectionPolicy.map { ["targetProjection="+$0] } ?? [])).joined(separator: "\n").utf8))
    }

    func iteration(_ ordinal: Int) throws -> Gemma4BenchmarkRequestInput {
        let original = try benchmark.iteration(ordinal)
        return .init(job: original.job, artifact: original.artifact, plan: original.plan,
            request: original.request, ordinal: ordinal,
            scopeSHA256: sha256(Data([scopeSHA256, "iteration=\(ordinal)", original.request.fingerprint]
                .joined(separator: "\n").utf8)))
    }

    func description() throws -> Data {
        let auxiliary = try Gemma4MTPAuxiliaryBudget(artifact: assistant, placement: .localTarget,
            requestSHA256: benchmark.requests[0].fingerprint,
            maximumFrontier: benchmark.requests[0].finalCommittedTokens, serialTargetHead: denseProjectionEnabled, bound: { $0 })
        return try canonicalJSONData(Gemma4LocalMTPCapability(job: job, scopeSHA256: scopeSHA256,
            ordinaryJobSHA256: job.benchmarkJobSHA256, assistantArtifactSHA256: Gemma4AssistantArtifact.aggregateSHA256,
            maximumDraftTokens: job.maximumDraftTokens, auxiliaryLogicalNativeBytes: auxiliary.liveNativeBytes,
            auxiliaryLogicalHostBytes: auxiliary.liveHostBytes, auxiliaryConstructorLogicalBytes: auxiliary.constructorBytes,
            qualification: qualifyConditioning,
            targetProjectionPolicy: targetProjectionPolicy))
    }
}

struct Gemma4LocalMTPCapability: Encodable {
    let schema = "gemma4_local_mtp_cohort_capability_v1"
    let job: Gemma4LocalMTPJob
    let scopeSHA256: String, ordinaryJobSHA256: String, assistantArtifactSHA256: String
    let maximumDraftTokens: Int
    let auxiliaryLogicalNativeBytes: Int, auxiliaryLogicalHostBytes: Int, auxiliaryConstructorLogicalBytes: Int
    let qualification: Bool
    let targetProjectionPolicy: String?
    let metadataOnly = true, actualAllocatorBoundsApplied = false
    let mtpEnabled = true, remoteAssistant = false, servingEnabled = false
    let targetBatchNumericsQualified = false, physicalOwnerRetirementEstablished = false
}
