import DarkbloomClusterProtocol
import Foundation
import MLX
import MLXNN

/// One Mac, both stages, no collective and no capture: the staged request as a
/// single Mac serves it, for timing by a clock outside this process. Stages
/// are loaded once; requests then run one after another, each reporting its
/// tokens as they are selected. This is what "one Mac alone" means when a pair
/// is compared with it on the same driver clock.
///
/// The frame path is the one a phase-split rank 1 runs after a hand-off:
/// stage 0, the residual handed straight to stage 1 when it is an owned compact
/// array (copied bit for bit otherwise), the pair's greedy selection. Nothing
/// is recorded, so it produces no evidence; correctness is the reference's job.
extension QwenStagedGenerationReference {
    public struct ServiceReady: Sendable {
        public let stageLoadSeconds: [Double]
        public let activeBytesBefore: Int
        public let activeBytesLoaded: Int
    }

    public struct ServiceCompletion: Sendable {
        public let selectedTokenIDs: [Int]
        public let finishReason: String
        /// This process's clock, from the call to `next` returning to the first
        /// selected token, and to both request states being retired.
        public let firstTokenNanoseconds: UInt64
        public let lastTokenNanoseconds: UInt64
        public let retiredNanoseconds: UInt64
        public let residualCopies: Int
        public let activeBytesDuringRequest: Int
        public let activeBytesAfterRetirement: Int
    }

    public struct ServiceRelease: Sendable {
        public let requests: Int
        public let stageModelsReleased: [Bool]
        public let activeBytesAfterRelease: Int
        public let cacheBytesAfterRelease: Int
        public let peakBytes: Int
    }

    /// `next` blocks until the next request and returns nil to shut down.
    /// `token` is called at each selection, before the next forward.
    public static func serve(modelDirectory: URL, stageCut: Int, deadlineUptimeNanoseconds: UInt64,
                             ready: (ServiceReady) throws -> Void, next: () throws -> Request?,
                             token: (_ ordinal: Int, _ tokenID: Int) throws -> Void,
                             finished: (ServiceCompletion) throws -> Void) throws -> ServiceRelease {
        let processEnvironment = ProcessInfo.processInfo.environment
        let nativeNames = ["JACCL_RANK", "MLX_RANK", "JACCL_IBV_DEVICES", "MLX_IBV_DEVICES",
            "JACCL_COORDINATOR", "MLX_JACCL_COORDINATOR", "JACCL_RING", "MLX_JACCL_RING"]
        guard nativeNames.allSatisfy({ processEnvironment[$0] == nil }) else {
            throw ProbeError("Staged service refuses a cluster transport environment; it creates no collective")
        }
        guard let specification = QwenDenseRegisteredSpecification.all.first(where: { $0.model == .qwen35NineB }) else {
            throw ProbeError("Registered 9B specification is unavailable")
        }
        let matrixPath = "/var/empty/darkbloom-staged-service.matrix.json"
        let matrix = Data(#"[[null,"staged-service-0"],["staged-service-1",null]]"#.utf8)
        let identity = ClusterWorkerIdentity(membershipEpoch: UUID(),
            modelID: QwenRegisteredDenseModel.qwen35NineB.rawValue,
            artifactSHA256: specification.artifactSHA256, configurationSHA256: specification.configurationSHA256,
            peers: (0...1).map { ClusterWorkerPeer(id: "staged-service-\($0)", buildSHA256: String(repeating: "0", count: 64)) })
        let configBytes = try BoundedProbeInput.data(modelDirectory.appendingPathComponent("config.json"), maximumBytes: 1_048_576)
        let manifestBytes = try BoundedProbeInput.data(modelDirectory.appendingPathComponent("manifest.json"), maximumBytes: 4_194_304)
        let admissions = try (0...1).map { rank -> QwenResidentAdmission in
            var environment = processEnvironment
            environment["JACCL_RANK"] = String(rank)
            environment["JACCL_IBV_DEVICES"] = matrixPath
            environment["JACCL_COORDINATOR"] = "127.0.0.1:1"
            return try QwenResidentAdmission(configuration: .init(identity: identity, modelDirectory: modelDirectory,
                    rank: rank, stageCut: stageCut, deadlineUptimeNanoseconds: deadlineUptimeNanoseconds,
                    allocatorPolicy: .disableFreedBufferCache),
                configBytes: configBytes, manifestBytes: manifestBytes, environment: environment,
                now: DispatchTime.now().uptimeNanoseconds,
                read: { url, limit in url.path == matrixPath ? matrix : try BoundedProbeInput.data(url, maximumBytes: limit) })
        }
        let plan = admissions[0].plan
        guard plan.fingerprint == admissions[1].plan.fingerprint,
              admissions[0].arithmeticSHA256 == admissions[1].arithmeticSHA256 else {
            throw ProbeError("Staged service admissions disagree on Plan or arithmetic")
        }
        let control = QwenResidentControl(deadline: deadlineUptimeNanoseconds)
        try QwenResidentProcessLease.shared.acquire()
        defer { QwenResidentProcessLease.shared.release() }
        try control.check()
        try QwenResidentResourceEnvironment.require()

        var stages: [QwenResidentLoadedStage] = []
        weak var retired0: Module?
        weak var retired1: Module?
        var sessions: [QwenLayerStageSession] = []
        return try MLX.withError { nativeError in
            func checked() throws { try nativeError.check(); try control.check(); try nativeError.check() }
            func settle() throws {
                Stream.gpu.synchronize(); Stream.cpu.synchronize()
                try nativeError.check()
            }
            do {
                try QwenResidentAllocatorPolicy.disableFreedBufferCache.configure(
                    setCacheLimit: { Memory.cacheLimit = $0 }, check: checked)
                try settle()
                let before = Memory.snapshot().activeMemory
                var loadSeconds: [Double] = []
                for rank in 0...1 {
                    let started = DispatchTime.now().uptimeNanoseconds
                    try autoreleasepool {
                        let loaded = try loadQwenResidentStage(admissions[rank], check: checked)
                        if rank == 0 { retired0 = loaded.loaded.model } else { retired1 = loaded.loaded.model }
                        stages.append(loaded)
                    }
                    try settle()
                    loadSeconds.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9)
                }
                try QwenResidentAllocatorPolicy.disableFreedBufferCache.prepareReady(
                    synchronize: { Stream.gpu.synchronize(); Stream.cpu.synchronize() },
                    snapshot: {
                        let now = Memory.snapshot()
                        return .init(activeBytes: now.activeMemory, cachedBytes: now.cacheMemory, peakBytes: now.peakMemory)
                    }, clearCache: { Memory.clearCache() }, check: checked)
                let receipts = stages.map(\.loaded.receipt)
                guard receipts[0].storageCommitmentSHA256 == receipts[1].storageCommitmentSHA256,
                      receipts[0].verifiedAggregateSHA256 == receipts[1].verifiedAggregateSHA256,
                      receipts[0].sourceParameterLayoutSHA256 == receipts[1].sourceParameterLayoutSHA256 else {
                    throw ProbeError("Staged service stages did not load matching verified commitments")
                }
                try ready(.init(stageLoadSeconds: loadSeconds, activeBytesBefore: before,
                                activeBytesLoaded: Memory.snapshot().activeMemory))

                var served = 0
                while let value = try next() {
                    let began = DispatchTime.now().uptimeNanoseconds
                    try checked()
                    let request = try admissions[0].request(.init(profileID: admissions[0].profile.identifier,
                            promptTokenIDs: value.promptTokenIDs, stopTokenIDs: value.stopTokenIDs,
                            outputCount: value.outputCount, chunkSize: value.chunkSize,
                            deadlineUptimeNanoseconds: deadlineUptimeNanoseconds, capacityLimitBytes: 1),
                        id: value.requestID, now: DispatchTime.now().uptimeNanoseconds)
                    // Each rank's named request allowance, checked live as the worker does.
                    let allowances = try (0...1).map {
                        try QwenResidentRequestAllowance.derive(profile: stages[$0].profile, plan: plan, rank: $0,
                            maximumTokens: request.maximumTokens, chunkSize: min(request.chunkSize, request.promptCount),
                            bound: QwenResidentResourceEnvironment.allocationBound)
                    }
                    var lastResourceCheck: UInt64 = 0
                    func live() throws {
                        try checked()
                        let now = DispatchTime.now().uptimeNanoseconds
                        if lastResourceCheck == 0 || now - lastResourceCheck >= 250_000_000 {
                            for allowance in allowances { try allowance.requireLive() }
                            lastResourceCheck = DispatchTime.now().uptimeNanoseconds
                        }
                        try checked()
                    }
                    try live()
                    for rank in 0...1 {
                        sessions.append(try QwenLayerStageSession(stage: stages[rank].loaded, plan: plan, generationRequest: request))
                    }
                    var tokens: [Int] = []
                    var first: UInt64 = 0, last: UInt64 = 0
                    var copies = 0
                    var reason: QwenLayerStageGenerationFinishReason?
                    for sequence in 0..<request.forwardCount {
                        let frame = try request.frame(sequence: sequence)
                        try autoreleasepool {
                            try live()
                            let ids: [Int]
                            if frame.phase == .prefill {
                                ids = Array(request.promptTokenIDs[frame.tokenOffset..<(frame.tokenOffset + frame.tokenCount)])
                            } else {
                                guard let previous = tokens.last else { throw ProbeError("Staged service decode lacks a selected token") }
                                ids = [previous]
                            }
                            func forward(_ rank: Int, _ incoming: QwenLayerStageBoundary?) throws -> QwenLayerStageOutput {
                                frame.phase == .prefill
                                    ? try sessions[rank].prefillChunk(ids, offset: frame.tokenOffset,
                                        final: frame.finalPromptChunk, incoming: incoming, check: live)
                                    : try sessions[rank].decode(ids[0], offset: frame.tokenOffset, incoming: incoming, check: live)
                            }
                            guard case .hidden(let produced) = try forward(0, nil) else {
                                throw ProbeError("Staged service stage 0 did not return a residual")
                            }
                            var incoming = produced
                            if !produced.hasOwnedCompactStorage {
                                incoming = try produced.ownedCopy(check: live); copies += 1
                            }
                            let output = try forward(1, incoming)
                            switch output {
                            case .evaluationHandle where frame.phase == .prefill && !frame.finalPromptChunk: return
                            case .logits(let row) where frame.finalPromptChunk || frame.phase == .decode:
                                let selected = try QwenLayerStageGenerationSelection.token(row, request: request, check: live)
                                last = DispatchTime.now().uptimeNanoseconds
                                if tokens.isEmpty { first = last }
                                try token(tokens.count, selected)
                                tokens.append(selected)
                                if request.stopTokenIDs.contains(selected) { reason = .eos }
                                else if tokens.count == request.outputCount { reason = .length }
                            default: throw ProbeError("Staged service stage 1 output does not match its frame")
                            }
                        }
                        if reason != nil { break }
                    }
                    guard let reason, let lastToken = tokens.last else {
                        throw ProbeError("Staged service ended without a selected-token completion")
                    }
                    let during = Memory.snapshot().activeMemory
                    for session in sessions {
                        try session.finishGeneration(reason, selectedTokenCount: tokens.count, lastTokenID: lastToken)
                        guard session.isClosed, !session.isFailed else { throw ProbeError("Staged service request state failed retirement") }
                    }
                    sessions.removeAll()
                    try settle()
                    let retired = DispatchTime.now().uptimeNanoseconds
                    served += 1
                    try finished(.init(selectedTokenIDs: tokens, finishReason: reason.rawValue,
                        firstTokenNanoseconds: first - began, lastTokenNanoseconds: last - began,
                        retiredNanoseconds: retired - began, residualCopies: copies,
                        activeBytesDuringRequest: during, activeBytesAfterRetirement: Memory.snapshot().activeMemory))
                }
                let peak = Memory.snapshot().peakMemory
                stages.removeAll()
                try settle()
                Memory.clearCache()
                try settle()
                let after = Memory.snapshot()
                return ServiceRelease(requests: served, stageModelsReleased: [retired0 == nil, retired1 == nil],
                    activeBytesAfterRelease: after.activeMemory, cacheBytesAfterRelease: after.cacheMemory, peakBytes: peak)
            } catch {
                var primary: Error = error
                do { try nativeError.check() } catch { primary = error }
                for session in sessions { try? session.cancel() }
                sessions.removeAll(); stages.removeAll()
                Stream.gpu.synchronize(); Stream.cpu.synchronize()
                Memory.clearCache()
                throw primary
            }
        }
    }
}
