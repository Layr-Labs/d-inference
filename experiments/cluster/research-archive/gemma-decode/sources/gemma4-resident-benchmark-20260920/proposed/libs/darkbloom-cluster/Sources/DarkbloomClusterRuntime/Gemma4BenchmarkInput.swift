import Foundation
import MLX

struct Gemma4BenchmarkJob: Codable {
    let schema: String, mode: String
    let modelDirectory: String, metadataDirectory: String, promptFile: String, promptFileSHA256: String
    let outputDirectory: String, membershipEpoch: String, buildIdentitySHA256: String, residualDType: String
    let requestIDs: [String]
    let promptCount: Int, chunkSize: Int, outputCount: Int, timeoutSeconds: Int, cut: Int
    let captureEvidence: Bool
    var rank: Int? { mode == "stage0" ? 0 : mode == "stage1" ? 1 : nil }
    var target: Gemma4ForwardTarget { rank.map(Gemma4ForwardTarget.stage) ?? .fullReference }
    var dtype: DType { residualDType == "bfloat16" ? .bfloat16 : residualDType == "float16" ? .float16 : .float32 }

    func validate() throws {
        guard schema == "gemma4_resident_benchmark_v1", ["full", "stage0", "stage1"].contains(mode),
              [128,256,1024,4096,8192].contains(promptCount), chunkSize == 128, outputCount == 16, [8,10].contains(cut),
              (1...300).contains(timeoutSeconds), requestIDs.count == 4, Set(requestIDs).count == 4,
              (requestIDs + [membershipEpoch]).allSatisfy({ UUID(uuidString: $0)?.uuidString.lowercased() == $0 }),
              [promptFileSHA256, buildIdentitySHA256].allSatisfy(qwenStageWireIsSHA256),
              ["float16", "bfloat16", "float32"].contains(residualDType),
              [modelDirectory, metadataDirectory, promptFile, outputDirectory].allSatisfy({
                  $0.hasPrefix("/") && $0.utf8.count <= 2048 && !$0.contains("\0")
                    && URL(fileURLWithPath: $0).standardizedFileURL.path == $0
              }), Set([modelDirectory, metadataDirectory, outputDirectory]).count == 3 else {
            throw ProbeError("Gemma benchmark job differs from closed identities/workload/lifetime/path bounds")
        }
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

struct Gemma4BenchmarkInput {
    let job: Gemma4BenchmarkJob
    let artifact: Gemma4ArtifactMetadata
    let plan: Gemma4LayerStagePlan
    let requests: [QwenLayerStageGenerationRequest]
    let scopeSHA256: String
    init(job: Gemma4BenchmarkJob) throws {
        try job.validate()
        let root = URL(fileURLWithPath: job.metadataDirectory, isDirectory: true)
        func data(_ name: String) throws -> Data {
            try BoundedProbeInput.data(root.appendingPathComponent(name), maximumBytes: 2_097_152)
        }
        let headers = try (1...3).map { index in
            let name = String(format: "model-%05d-of-00003.safetensors", index)
            return LayerStageCapturedTensorHeader(sourceFile: name, data: try data(name + ".header.json"))
        }
        artifact = try Gemma4ArtifactMetadata.admit(configuration: data("config.json"), manifest: data("manifest.json"),
            index: data("model.safetensors.index.json"), headers: headers)
        plan = try Gemma4LayerStagePlan(artifact: artifact, cut: job.cut)
        let raw = try BoundedProbeInput.data(URL(fileURLWithPath: job.promptFile), maximumBytes: 131_072)
        guard sha256(raw) == job.promptFileSHA256 else { throw ProbeError("Gemma benchmark prompt packet changed") }
        try validateWorkerJSON(raw)
        let tokens = try JSONDecoder().decode([Int].self, from: raw)
        guard tokens.count == job.promptCount else { throw ProbeError("Gemma benchmark prompt count differs") }
        requests = try job.requestIDs.map { try Gemma4ForwardRequest.make(requestID: UUID(uuidString: $0)!,
            tokens: tokens, chunkSize: job.chunkSize, outputCount: job.outputCount, stopTokenIDs: [], observedResidualDType: job.dtype) }
        self.job = job
        scopeSHA256 = sha256(Data((["gemma4-resident-benchmark-v1", job.membershipEpoch, job.buildIdentitySHA256,
            plan.fingerprint, job.promptFileSHA256, "cut=\(job.cut)", "warmup=1", "measure=3", "mtp=false",
            "capture=\(job.captureEvidence)"] + requests.map(\.fingerprint)).joined(separator: "\n").utf8))
    }
    func iteration(_ ordinal: Int) throws -> Gemma4BenchmarkRequestInput {
        guard requests.indices.contains(ordinal) else { throw ProbeError("Gemma benchmark iteration differs") }
        return .init(job: job, artifact: artifact, plan: plan, request: requests[ordinal], ordinal: ordinal,
            scopeSHA256: sha256(Data([scopeSHA256, "iteration=\(ordinal)", requests[ordinal].fingerprint].joined(separator: "\n").utf8)))
    }
    func description() throws -> Data {
        var targets: [[String: Any]] = []
        for target in [Gemma4ForwardTarget.fullReference, .stage(0), .stage(1)] {
            let budget = try Gemma4BenchmarkResourceBudget.derive(plan: plan, target: target,
                request: requests[0], captureEvidence: job.captureEvidence, bound: { $0 })
            targets.append(["target": target == .fullReference ? "full" : target == .stage(0) ? "stage0" : "stage1",
                "selectedTensorCount": budget.selected.count,
                "selectedBytes": try QwenLongPrefillCheckedBytes.sum(budget.selected.map { $0.source.layout.byteCount }),
                "namedNativeLogicalBytes": budget.namedNativeBytes, "hostEvidenceBytes": budget.hostEvidenceBytes,
                "stateLogicalBytes": budget.stateLogicalBytes,
                "minimumFreeBeforeLoadLogicalLowerBound": max(QwenDenseStageLoadPolicy.minimumActualFreeBytes,
                    try QwenLongPrefillCheckedBytes.sum([QwenLongPrefillCheckedBytes.sum(budget.selectedBounds),
                        budget.largestHostTensorBytes, budget.largestNativeCopyBytes, CheckpointAlignedReadPlan.maximumScratchAllocationBytes,
                        budget.namedNativeBytes, budget.hostEvidenceBytes, QwenDenseStageLoadPolicy.loadingHeadroomBytes]))])
        }
        return try JSONSerialization.data(withJSONObject: [
            "schema": "gemma4_resident_benchmark_capability_v1", "job": JSONSerialization.jsonObject(with: canonicalJSONData(job)),
            "artifactSHA256": Gemma4ArtifactMetadata.artifactAggregateSHA256, "configurationSHA256": Gemma4ArtifactMetadata.configurationSHA256,
            "planSHA256": plan.fingerprint, "mappingSHA256": plan.conservation.fingerprint,
            "scopeSHA256": scopeSHA256, "requestSHA256s": requests.map(\.fingerprint),
            "promptTokenIDsSHA256": qwenGenerationTokenHash(requests[0].promptTokenIDs), "targets": targets,
            "warmupRequests": 1, "measuredRequests": 3, "cut": job.cut, "cachePolicy": "disable_freed_buffer_cache_v1",
            "minimumActualFreeBytes": 6 * 1_073_741_824, "loadingHeadroomBytes": 4 * 1_073_741_824,
            "allocatorHeadroomBytes": 2 * 1_073_741_824, "requiredPressureLevel": 1,
            "requiresAC": true, "maximumSwapBytes": 0, "metadataOnly": true,
            "actualAllocatorBoundsApplied": false, "buildIdentityRequiresParentVerification": true,
            "runtimeExecutionAuthorized": false, "servingEnabled": false, "encryptedRDMA": false],
            options: [.sortedKeys, .withoutEscapingSlashes])
    }
}

struct Gemma4BenchmarkRequestInput {
    let job: Gemma4BenchmarkJob, artifact: Gemma4ArtifactMetadata, plan: Gemma4LayerStagePlan
    let request: QwenLayerStageGenerationRequest
    let ordinal: Int
    let scopeSHA256: String
}

enum Gemma4BenchmarkFrames {
    static func frame(_ sequence: Int, request: QwenLayerStageGenerationRequest) throws -> QwenLayerStageFrame {
        let prefillCount = (request.promptCount + request.chunkSize - 1) / request.chunkSize
        guard (0..<(prefillCount + request.outputCount - 1)).contains(sequence) else {
            throw ProbeError("Gemma benchmark frame outside its admitted request")
        }
        if sequence < prefillCount {
            let offset = sequence * request.chunkSize, count = min(request.chunkSize, request.promptCount - offset)
            return .init(sequence: sequence, phase: .prefill, tokenOffset: offset, tokenCount: count,
                         finalPromptChunk: offset + count == request.promptCount)
        }
        return .init(sequence: sequence, phase: .decode, tokenOffset: request.promptCount + sequence - prefillCount,
                     tokenCount: 1, finalPromptChunk: false)
    }
    static func probeCount(_ sequence: Int) throws -> Int { try Gemma4ShortFrames.probeCount(sequence) }
}

typealias Gemma4BenchmarkWireValue = Gemma4ShortWireValue
typealias Gemma4BenchmarkWirePacket = Gemma4ShortWirePacket
