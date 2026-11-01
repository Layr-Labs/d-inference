import Foundation
import MLX

/// One Mac, the registered GLM artifact, no collective: both stages of one
/// cut loaded in one process (each through its own verified resident stage,
/// with the serving envelope's quotes) and one request run through them,
/// stage 0 then stage 1, with the same sessions, chunking and greedy
/// selection a two-Mac pair uses. The residual crosses as an owned copy. This
/// is the single-Mac reference a pair's tokens and step rows are compared
/// with; it needs a Mac that holds the whole text model. Not a serving path.
///
/// The report uses MiMo's reference schema (`mimo_staged_reference_v2`):
/// the comparator reads tokens, step rows, artifact, Plan and storage
/// commitment from it, none of which is MiMo-specific.
public enum GLM5NextStagedReference {
    public typealias Request = MiMoStagedReference.Request

    public struct Result: Encodable, Sendable {
        public let schema = "mimo_staged_reference_v2"
        public let runtimeModelID: String
        public let stageCut: Int
        public let requestID: String
        public let promptTokens: Int
        public let selectedTokenIDs: [Int]
        public let finishReason: String
        public let steps: [MiMoStepEvidence]
        public let verifiedAggregateSHA256: String
        public let planSHA256: String
        public let storageCommitmentSHA256: String
        public let loadSeconds: [Double]
        public let prefillSeconds: Double
        public let decodeSeconds: Double
        public let activeBytesLoaded: Int, peakBytes: Int
        public let modelsReleased: [Bool]
    }

    private final class Held {
        let binding: GLM5NextStageBinding
        init(_ binding: GLM5NextStageBinding) { self.binding = binding }
    }

    public static func run(modelDirectory: URL, stageCut: Int, request value: Request,
                           deadlineUptimeNanoseconds: UInt64) throws -> Result {
        let configuration = try BoundedProbeInput.data(modelDirectory.appendingPathComponent("config.json"),
            maximumBytes: GLM5NextRegisteredSpecification.maximumConfigurationBytes)
        let manifest = try BoundedProbeInput.data(modelDirectory.appendingPathComponent("manifest.json"),
            maximumBytes: GLM5NextRegisteredSpecification.maximumManifestBytes)
        let spec = try GLM5NextRegisteredSpecification.specification(configuration: configuration)
        // Quoted for this one request: the reference holds both stages at once.
        let chunk = min(value.chunkSize, value.promptTokenIDs.count)
        let descriptor = try spec.descriptor(configuration: configuration, manifest: manifest, cut: stageCut,
            requestScope: (value.promptTokenIDs.count, chunk, value.outputCount))
        let inventory = try descriptor.inspectInventory(directory: modelDirectory)
        guard GLM5NextArtifactMetadata.fingerprint(inventory) == spec.inventorySHA256 else {
            throw ProbeError("GLM reference requires the registered header inventory")
        }
        let request = try QwenLayerStageGenerationRequest(profile: descriptor.profile, requestID: value.requestID,
            // A chunk longer than the prompt is one frame of the whole prompt either way.
            promptTokenIDs: value.promptTokenIDs, chunkSize: chunk, outputCount: value.outputCount,
            stopTokenIDs: Set(value.stopTokenIDs))
        let control = QwenResidentControl(deadline: deadlineUptimeNanoseconds)
        func checked() throws { try control.check() }
        try QwenResidentResourceEnvironment.require()
        let build = String(repeating: "0", count: 64)

        var residents: [GLM5NextResidentStage] = []
        var held: [GLM5NextResidentStage.Borrow<Held>] = []
        weak var released0: Held?
        weak var released1: Held?
        do {
            var loadSeconds: [Double] = []
            for rank in 0...1 {
                let started = DispatchTime.now().uptimeNanoseconds
                let envelope = try GLM5NextServingResources.envelope(descriptor: descriptor, inventory: inventory,
                    rank: rank, buildSHA256: build)
                let budget = try envelope.budget(descriptor: descriptor)
                let resident = try GLM5NextResidentStage(directory: modelDirectory,
                    expectedIdentity: descriptor.artifactIdentity, artifactAggregateSHA256: spec.artifactSHA256,
                    storage: spec.storage, stageIndex: rank, cut: stageCut, includeMTP: false,
                    executionPolicy: spec.executionPolicy, capacityLimitBytes: envelope.loadCapacityBytes,
                    executionStateReserveBytes: budget.nativeBytes - budget.workspaceNativeBytes,
                    workspaceReserveBytes: budget.workspaceNativeBytes, processLease: QwenResidentProcessLease())
                residents.append(resident)
                try resident.load(check: checked)
                held.append(try resident.borrowComponent { stage, mtp in
                    guard mtp == nil else { throw ProbeError("GLM reference stage loaded an MTP head") }
                    return Held(stage)
                })
                loadSeconds.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9)
            }
            released0 = held[0].value; released1 = held[1].value
            // Both stages share this process, so one residency holds them both.
            Stream.gpu.synchronize(); Stream.cpu.synchronize()
            var residency: ClusterStageResidency? = try ClusterStageResidency(bytes: try QwenLongPrefillCheckedBytes.sum(
                residents.flatMap { [$0.receipt?.selectedPayloadBytes ?? 0, $0.receipt?.reservedBytes ?? 0] }))
            defer { try? residency?.end(); residency = nil }
            // Sessions and bindings live only inside this scope, so every
            // external owner is gone before the residents are closed.
            let run = try generate(held.map(\.value.binding), request: request, build: build, check: checked)
            let peak = Memory.snapshot().peakMemory
            // The wired limit goes back before the stages' tensors are released.
            try residency?.end(); residency = nil
            held.removeAll()
            for resident in residents { try resident.close(peerFence: {}, check: {}) }
            residents.removeAll()
            Stream.gpu.synchronize(); Memory.clearCache()
            return Result(runtimeModelID: spec.model.rawValue, stageCut: stageCut,
                requestID: request.requestID.uuidString.lowercased(), promptTokens: request.promptCount,
                selectedTokenIDs: run.tokens, finishReason: run.reason.rawValue, steps: run.steps,
                verifiedAggregateSHA256: spec.artifactSHA256, planSHA256: run.plan,
                storageCommitmentSHA256: run.commitment, loadSeconds: loadSeconds, prefillSeconds: run.prefill,
                decodeSeconds: run.decode, activeBytesLoaded: run.loaded, peakBytes: peak,
                modelsReleased: [released0 == nil, released1 == nil])
        } catch {
            held.removeAll()
            for resident in residents { try? resident.close(peerFence: {}, check: {}) }
            Stream.gpu.synchronize(); Memory.clearCache()
            throw error
        }
    }

    private struct Generated {
        let tokens: [Int], reason: QwenLayerStageGenerationFinishReason, steps: [MiMoStepEvidence]
        let prefill: Double, decode: Double, loaded: Int, plan: String, commitment: String
    }

    private static func generate(_ bindings: [GLM5NextStageBinding], request: QwenLayerStageGenerationRequest,
                                 build: String, check checked: () throws -> Void) throws -> Generated {
        let contract = bindings[1].contract
        guard bindings[0].contract.source == contract.source,
              bindings[0].contract.stageFingerprints == contract.stageFingerprints else {
            throw ProbeError("The two GLM reference stages disagree on their contract")
        }
        let agreement = try QwenLayerStageGenerationAgreement(request: request, membershipEpoch: UUID(),
            source: contract.source, consumerStageFingerprint: contract.stageFingerprints[1],
            rankBuildSHA256: [build, build], numericalPolicySHA256: contract.numericalPolicySHA256)
        let sessions = try bindings.map { try GLM5NextStageSession(stage: $0, agreement: agreement) }
        let loaded = Memory.snapshot().activeMemory
        var tokens: [Int] = [], steps: [MiMoStepEvidence] = []
        var reason = QwenLayerStageGenerationFinishReason.length
        var prefill = 0.0, decode = 0.0, index = 0
        while tokens.count < request.outputCount {
            try checked()
            let row: MLXArray? = try autoreleasepool {
                let frame = try request.frame(sequence: index)
                index += 1
                let ids = frame.phase == .prefill
                    ? Array(request.promptTokenIDs[frame.tokenOffset..<(frame.tokenOffset + frame.tokenCount)])
                    : [tokens[tokens.count - 1]]
                let clock = DispatchTime.now().uptimeNanoseconds
                guard case .hidden(let boundary) = try sessions[0].forward(frame: frame, tokens: ids,
                    afterEvaluation: { _ in }, check: checked) else {
                    throw ProbeError("GLM reference stage 0 returned no residual")
                }
                let output = try sessions[1].forward(frame: frame, tokens: ids,
                    incoming: try boundary.ownedCopy(check: checked), afterEvaluation: { _ in }, check: checked)
                let seconds = Double(DispatchTime.now().uptimeNanoseconds - clock) / 1e9
                if frame.phase == .prefill { prefill += seconds } else { decode += seconds }
                if case .logits(let logits) = output {
                    let bytes = logits.asData().data, dtype = String(describing: logits.dtype)
                    steps.append(MiMoStepEvidence(ordinal: tokens.count, boundarySHA256: boundary.payloadSHA256,
                        rowSHA256: sha256(bytes), rowDType: dtype,
                        top: try MiMoStepEvidence.candidates(rowBytes: bytes, dtype: dtype)))
                    return logits
                }
                return nil
            }
            guard let row else { continue }
            let token = try QwenLayerStageGenerationSelection.token(row, request: request, check: checked)
            tokens.append(token)
            if request.stopTokenIDs.contains(token) { reason = .eos; break }
        }
        for session in sessions { try session.close(check: checked) }
        return Generated(tokens: tokens, reason: reason, steps: steps, prefill: prefill, decode: decode,
            loaded: loaded, plan: contract.source.planFingerprint, commitment: contract.source.storageCommitmentSHA256)
    }
}
