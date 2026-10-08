import Foundation
import MLX

struct Gemma4ShortCheckJob: Codable {
    let schema: String
    let mode: String
    let modelDirectory: String
    let metadataDirectory: String
    let promptFile: String
    let promptFileSHA256: String
    let outputDirectory: String
    let requestID: String
    let membershipEpoch: String
    let buildIdentitySHA256: String
    let residualDType: String
    let timeoutSeconds: Int

    var rank: Int? { mode == "stage0" ? 0 : mode == "stage1" ? 1 : nil }
    var target: Gemma4ForwardTarget { rank.map(Gemma4ForwardTarget.stage) ?? .fullReference }
    var dtype: DType {
        switch residualDType { case "float16": return .float16; case "bfloat16": return .bfloat16; default: return .float32 }
    }
    func validate() throws {
        guard schema == "gemma4_short_native_check_v1", ["full", "stage0", "stage1"].contains(mode),
              (1...300).contains(timeoutSeconds), ["float16", "bfloat16", "float32"].contains(residualDType),
              [promptFileSHA256, buildIdentitySHA256].allSatisfy(qwenStageWireIsSHA256),
              [requestID, membershipEpoch].allSatisfy({ UUID(uuidString: $0)?.uuidString.lowercased() == $0 }),
              [modelDirectory, metadataDirectory, promptFile, outputDirectory].allSatisfy({
                  $0.hasPrefix("/") && $0.utf8.count <= 2048 && !$0.contains("\0")
                    && URL(fileURLWithPath: $0).standardizedFileURL.path == $0
              }), Set([modelDirectory, metadataDirectory, outputDirectory]).count == 3 else {
            throw ProbeError("Gemma short job differs from closed mode/identity/path/lifetime bounds")
        }
    }
    static func read(_ url: URL) throws -> Self {
        let bytes = try BoundedProbeInput.data(url, maximumBytes: 16_384)
        try validateWorkerJSON(bytes)
        let value = try JSONDecoder().decode(Self.self, from: bytes)
        try value.validate()
        try QwenLayerStageGenerationWireJSON.requireExact(
            QwenLayerStageGenerationWireJSON.object(bytes), value)
        return value
    }
}

struct Gemma4ShortCheckInput {
    let job: Gemma4ShortCheckJob
    let artifact: Gemma4ArtifactMetadata
    let plan: Gemma4LayerStagePlan
    let request: QwenLayerStageGenerationRequest
    let scopeSHA256: String

    init(job: Gemma4ShortCheckJob) throws {
        try job.validate()
        let root = URL(fileURLWithPath: job.metadataDirectory, isDirectory: true)
        func data(_ name: String) throws -> Data {
            try BoundedProbeInput.data(root.appendingPathComponent(name), maximumBytes: 2_097_152)
        }
        let headers = try (1...3).map { index in
            let name = String(format: "model-%05d-of-00003.safetensors", index)
            return LayerStageCapturedTensorHeader(sourceFile: name, data: try data(name + ".header.json"))
        }
        let artifact = try Gemma4ArtifactMetadata.admit(configuration: data("config.json"),
            manifest: data("manifest.json"), index: data("model.safetensors.index.json"), headers: headers)
        let plan = try Gemma4LayerStagePlan(artifact: artifact, cut: Gemma4ShortResourceBudget.candidateCut)
        let raw = try BoundedProbeInput.data(URL(fileURLWithPath: job.promptFile), maximumBytes: 4096)
        guard sha256(raw) == job.promptFileSHA256 else { throw ProbeError("Gemma prompt packet changed") }
        try validateWorkerJSON(raw)
        let tokens = try JSONDecoder().decode([Int].self, from: raw)
        guard tokens.count == 32 else { throw ProbeError("Gemma short check requires32 pinned IDs") }
        let request = try Gemma4ForwardRequest.make(requestID: UUID(uuidString: job.requestID)!, tokens: tokens,
            chunkSize: 16, outputCount: 2, stopTokenIDs: [], observedResidualDType: job.dtype)
        self.job = job; self.artifact = artifact; self.plan = plan; self.request = request
        scopeSHA256 = sha256(Data(["gemma4-short-correctness-v1", job.membershipEpoch, job.buildIdentitySHA256,
            plan.fingerprint, request.fingerprint, job.promptFileSHA256,
            "exact-bytes-before-any-numerical-qualification", "mtp=false", "cut=10"].joined(separator: "\n").utf8))
    }

    func description() throws -> Gemma4ShortDescription {
        let targets: [(String, Gemma4ForwardTarget, [Int])] = [("full-reference", .fullReference, Array(0..<30)),
            ("stage-0", .stage(0), Array(0..<10)), ("stage-1", .stage(1), Array(10..<30))]
        let projections = try targets.map { name, target, globals in
            let selected = try Gemma4ForwardSelection.make(plan: plan, target: target)
            let layout = selected.map { "\($0.localName):\($0.loadedDType):\($0.source.layout.shape)" }.sorted().joined(separator: "\n")
            return Gemma4ShortDescription.Target(name: name, parameterLayoutSHA256: sha256(Data(layout.utf8)),
                selectedTensorCount: selected.count, selectedBytes: selected.reduce(0) { $0 + $1.source.layout.byteCount },
                globalLayerIndices: globals)
        }
        return .init(scopeSHA256: scopeSHA256, membershipEpoch: job.membershipEpoch,
            buildIdentitySHA256: job.buildIdentitySHA256, requestID: job.requestID,
            requestSHA256: request.fingerprint, promptFileSHA256: job.promptFileSHA256,
            promptTokenIDsSHA256: qwenGenerationTokenHash(request.promptTokenIDs),
            profile: request.profile, planSHA256: plan.fingerprint,
            stageSHA256: plan.stages.map(\.fingerprint), mappingSHA256: plan.conservation.fingerprint, targets: projections)
    }
}
