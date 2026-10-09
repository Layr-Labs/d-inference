import Foundation
import MLX
import MLXNN

/// One Mac, the real artifact, no collective: both stages of one cut loaded in
/// one process and one request run through them, stage 0 then stage 1, with
/// the same sessions, chunking and greedy selection a two-Mac pair uses. The
/// residual crosses as an owned copy of its bytes. This is the single-Mac
/// reference a pair's tokens are compared with; it needs a Mac that can hold
/// the whole text model, and it is not a serving result.
public enum MiMoStagedReference {
    public struct Request: Sendable {
        public let requestID: UUID
        public let promptTokenIDs: [Int]
        public let stopTokenIDs: [Int]
        public let chunkSize: Int
        public let outputCount: Int
        public init(requestID: UUID, promptTokenIDs: [Int], stopTokenIDs: [Int], chunkSize: Int, outputCount: Int) {
            self.requestID = requestID; self.promptTokenIDs = promptTokenIDs; self.stopTokenIDs = stopTokenIDs
            self.chunkSize = chunkSize; self.outputCount = outputCount
        }
    }

    public struct Result: Encodable, Sendable {
        public let schema = "mimo_staged_reference_v1"
        public let runtimeModelID: String
        public let stageCut: Int
        public let requestID: String
        public let promptTokens: Int
        public let selectedTokenIDs: [Int]
        public let finishReason: String
        /// The chain over every residual that crossed the cut, as both stages computed it.
        public let boundaryChainSHA256: String
        public let lastRowSHA256: String?
        public let verifiedAggregateSHA256: String
        public let planSHA256: String
        public let storageCommitmentSHA256: String
        public let loadedTensorBytes: [Int]
        public let residency: Bool
        public let wiredLimitBytes: Int
        /// In-process clock: summed frame times, and the request from its
        /// first frame to retirement. None of these is a serving figure.
        public let loadSeconds: Double
        public let prefillSeconds: Double
        public let decodeSeconds: Double
        public let requestSeconds: Double
        public let activeBytesLoaded: Int, peakBytes: Int
        public let activeBytesAfterRelease: Int, cacheBytesAfterRelease: Int
        public let modelsReleased: [Bool]
        public let resourceAdmission: QwenResidentResourceAdmissionReport
    }

    public static func run(modelDirectory: URL, stageCut: Int, request value: Request,
                           deadlineUptimeNanoseconds: UInt64, residency keepsResidency: Bool = true) throws -> Result {
        let configuration = try BoundedProbeInput.data(modelDirectory.appendingPathComponent("config.json"),
                                                       maximumBytes: 1_048_576)
        let manifest = try BoundedProbeInput.data(modelDirectory.appendingPathComponent("manifest.json"),
                                                  maximumBytes: 4_194_304)
        let specification = try MiMoRegisteredSpecification.specification(configuration: configuration)
        guard specification.supportedCuts.contains(stageCut), sha256(manifest) == specification.manifestSHA256 else {
            throw ProbeError("MiMo reference requires the registered manifest and one of the model's cuts")
        }
        _ = try MiMoArithmeticEnvironment.admit(ProcessInfo.processInfo.environment)
        let plan = try MiMoLayerStagePlan(configuration: configuration, cut: stageCut)
        let request = try QwenLayerStageGenerationRequest(profile: specification.profile(), requestID: value.requestID,
            promptTokenIDs: value.promptTokenIDs, chunkSize: value.chunkSize, outputCount: value.outputCount,
            stopTokenIDs: Set(value.stopTokenIDs))
        let control = QwenResidentControl(deadline: deadlineUptimeNanoseconds)
        try QwenResidentProcessLease.shared.acquire()
        defer { QwenResidentProcessLease.shared.release() }
        try control.check()
        try QwenResidentResourceEnvironment.require()

        var stages: [LoadedMiMoLayerStage] = []
        weak var retired0: Module?
        weak var retired1: Module?
        var wired: MiMoStageResidency?
        return try MLX.withError { nativeError in
            func checked() throws { try nativeError.check(); try control.check(); try nativeError.check() }
            func settle() throws { Stream.gpu.synchronize(); Stream.cpu.synchronize(); try nativeError.check() }
            do {
                try settle()
                let started = DispatchTime.now().uptimeNanoseconds
                try autoreleasepool {
                    let source = try prepareMiMoResidentSource(directory: modelDirectory, configuration: configuration,
                        manifest: manifest, specification: specification, plan: plan, check: checked)
                    stages.append(try loadMiMoResidentStage(source: source, stageIndex: 0, check: checked,
                                                            constructed: { retired0 = $0 }))
                    stages.append(try loadMiMoResidentStage(source: source, stageIndex: 1, check: checked,
                                                            constructed: { retired1 = $0 }))
                }
                try settle()
                let loadSeconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9
                guard stages.count == 2,
                      stages[0].receipt.storageCommitmentSHA256 == stages[1].receipt.storageCommitmentSHA256 else {
                    throw ProbeError("The two MiMo stages did not load matching storage commitments")
                }
                let loadedBytes = stages.map(\.receipt.loadedTensorBytes)
                let allowances = try (0...1).map {
                    try MiMoResidentRequestAllowance.derive(specification: specification, plan: plan, rank: $0,
                        maximumTokens: request.maximumTokens, chunkSize: min(request.chunkSize, request.promptCount))
                }
                try allowances[0].requireLive(); try allowances[1].requireLive()
                if keepsResidency {
                    wired = try MiMoStageResidency(bytes: loadedBytes[0] + loadedBytes[1]
                        + allowances[0].reservedBytes + allowances[1].reservedBytes)
                }
                let active = Memory.snapshot().activeMemory
                var tokens: [Int] = [], reason = QwenLayerStageGenerationFinishReason.length
                var prefill = 0.0, decode = 0.0
                var chain = "", row: String?
                let begun = DispatchTime.now().uptimeNanoseconds
                try autoreleasepool {
                    let sessions = try stages.map {
                        try MiMoLayerStageSession(stage: $0, plan: plan, generationRequest: request)
                    }
                    func frame(_ index: Int) throws -> MLXArray? {
                        let frame = try request.frame(sequence: index)
                        let ids = frame.phase == .prefill
                            ? Array(request.promptTokenIDs[frame.tokenOffset..<(frame.tokenOffset + frame.tokenCount)])
                            : [tokens[tokens.count - 1]]
                        let clock = DispatchTime.now().uptimeNanoseconds
                        func forward(_ session: MiMoLayerStageSession, _ incoming: QwenLayerStageBoundary?) throws -> QwenLayerStageOutput {
                            frame.phase == .prefill
                                ? try session.prefillChunk(ids, offset: frame.tokenOffset, final: frame.finalPromptChunk,
                                                           incoming: incoming, check: checked)
                                : try session.decode(ids[0], offset: frame.tokenOffset, incoming: incoming, check: checked)
                        }
                        guard case .hidden(let boundary) = try forward(sessions[0], nil) else {
                            throw ProbeError("MiMo reference stage 0 returned no residual")
                        }
                        let output = try forward(sessions[1], try boundary.ownedCopy(check: checked))
                        let seconds = Double(DispatchTime.now().uptimeNanoseconds - clock) / 1e9
                        if frame.phase == .prefill { prefill += seconds } else { decode += seconds }
                        if case .logits(let logits) = output { return logits }
                        return nil
                    }
                    var index = 0
                    while tokens.count < request.outputCount {
                        try checked()
                        guard let logits = try autoreleasepool(invoking: { try frame(index) }) else { index += 1; continue }
                        index += 1
                        let token = try QwenLayerStageGenerationSelection.token(logits, request: request, check: checked)
                        tokens.append(token)
                        if request.stopTokenIDs.contains(token) { reason = .eos; break }
                    }
                    guard let lastToken = tokens.last else { throw ProbeError("MiMo reference selected no token") }
                    guard sessions[0].boundaryChainSHA256 == sessions[1].boundaryChainSHA256 else {
                        throw ProbeError("The two MiMo stages saw different residuals")
                    }
                    chain = sessions[0].boundaryChainSHA256; row = sessions[1].lastRowSHA256
                    for session in sessions {
                        try session.finishGeneration(reason, selectedTokenCount: tokens.count, lastTokenID: lastToken)
                    }
                }
                try settle()
                let requestSeconds = Double(DispatchTime.now().uptimeNanoseconds - begun) / 1e9
                let peak = Memory.snapshot().peakMemory
                let limit = wired?.receipt.appliedBytes ?? 0
                try wired?.end(); wired = nil
                let aggregate = stages[0].receipt.verifiedAggregateSHA256
                let commitment = stages[0].receipt.storageCommitmentSHA256
                stages.removeAll()
                try settle()
                Memory.clearCache()
                try settle()
                let after = Memory.snapshot()
                return Result(runtimeModelID: specification.model.rawValue, stageCut: stageCut,
                    requestID: request.requestID.uuidString.lowercased(), promptTokens: request.promptCount,
                    selectedTokenIDs: tokens, finishReason: reason.rawValue, boundaryChainSHA256: chain,
                    lastRowSHA256: row, verifiedAggregateSHA256: aggregate, planSHA256: plan.fingerprint,
                    storageCommitmentSHA256: commitment, loadedTensorBytes: loadedBytes, residency: keepsResidency,
                    wiredLimitBytes: limit, loadSeconds: loadSeconds, prefillSeconds: prefill, decodeSeconds: decode,
                    requestSeconds: requestSeconds, activeBytesLoaded: active, peakBytes: peak,
                    activeBytesAfterRelease: after.activeMemory, cacheBytesAfterRelease: after.cacheMemory,
                    modelsReleased: [retired0 == nil, retired1 == nil], resourceAdmission: .current)
            } catch {
                var primary: Error = error
                try? wired?.end(); wired = nil
                stages.removeAll()
                Stream.gpu.synchronize(); Stream.cpu.synchronize()
                Memory.clearCache()
                do { try nativeError.check() } catch { primary = error }
                let after = Memory.snapshot()
                throw QwenResidentReleasedFailure(failure: String(describing: primary),
                    activeBytesAfterRelease: after.activeMemory, cacheBytesAfterRelease: after.cacheMemory,
                    modelsReleased: [retired0 == nil, retired1 == nil], resourceAdmission: .current)
            }
        }
    }
}
