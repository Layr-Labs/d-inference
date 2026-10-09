import DarkbloomClusterProtocol
import Foundation
import MLX
import MLXNN

/// One Mac, both stages of the registered artifact, no collective. It runs the
/// same staged request a two-Mac pair runs: stage 0 produces the residual for a
/// frame, the residual is physically copied, stage 1 consumes the copy and, on
/// the final prompt chunk and every decode frame, the pair's own greedy
/// selection picks the token. Loader, admission, sessions, frame schedule and
/// selection are the worker's; only the transfer between stages differs.
///
/// It is a comparison reference, not a serving path: it holds both stages in
/// one process, copies every target row to the CPU, and runs each rank's
/// recording capture so the records a recording worker would write exist for
/// this history too.
public enum QwenStagedGenerationReference {
    public struct Request: Sendable {
        public let requestID: UUID
        public let promptTokenIDs: [Int]
        public let stopTokenIDs: [Int]
        public let chunkSize: Int
        public let outputCount: Int
        public init(requestID: UUID, promptTokenIDs: [Int], stopTokenIDs: [Int], chunkSize: Int, outputCount: Int) {
            self.requestID = requestID; self.promptTokenIDs = promptTokenIDs
            self.stopTokenIDs = stopTokenIDs; self.chunkSize = chunkSize; self.outputCount = outputCount
        }
    }

    /// One selected token. `topTokenIDs`/`topLogits` are the row's largest
    /// values in descending order (ties by lower token ID), so a later
    /// divergence at this step can be judged against the margin here.
    public struct Step: Sendable {
        public let ordinal: Int
        public let frameSequence: Int
        public let committedTokens: Int
        public let tokenID: Int
        public let topTokenIDs: [Int]
        public let topLogits: [Float]
        public let maximumTieCount: Int
        public let rowSHA256: String
        /// Stage 0 forward, copy, stage 1 forward and selection for this frame.
        public let forwardNanoseconds: UInt64
    }

    /// A stage 0 residual that the pair's sender would have refused: it sends
    /// the array's own storage and requires an owned, compact allocation.
    public struct UnownedResidual: Sendable {
        public let frameSequence: Int
        public let phase: String
        public let tokenCount: Int
        public let byteCount: Int
        public let allocatedBytes: Int
        public let allocationBound: Int
        public let dataOffset: Int
        public let dataElements: Int
        public let elementCount: Int
        public let isUnique: Bool
        public let isRowContiguous: Bool
        /// The same check again after the GPU stream has drained.
        public let ownedAfterGPUSynchronize: Bool
    }

    public struct StateEntry: Sendable {
        public let globalLayerIndex: Int
        public let component: String
        public let shape: [Int]
        public let dtype: String
        public let byteCount: Int
        public let sha256: String
    }

    public struct Result: Sendable {
        public let requestFingerprint: String
        public let profileID: String
        public let profileFingerprint: String
        public let planSHA256: String
        public let stageSHA256: [String]
        public let artifactSHA256: String
        public let configurationSHA256: String
        public let storageCommitmentSHA256: String
        public let arithmeticContract: String
        public let arithmeticSHA256: String
        public let stageCut: Int
        public let layerCount: Int

        public let selectedTokenIDs: [Int]
        public let finishReason: String
        public let completedFrames: Int
        public let committedTokens: Int
        public let steps: [Step]
        public let finalLogitsShape: [Int]
        public let finalLogitsDType: String
        public let finalLogitsByteCount: Int
        public let finalLogitsSHA256: String
        public let finalLogits: [Float]
        public let stateEntries: [StateEntry]
        public let stateSHA256: String
        /// This history as each rank's recording worker would write it: the
        /// runtime's final-diagnostic record, one per stage, produced by the
        /// pair's own capture and encoded by the same type. A reader of pair
        /// sidecars can be checked against real output without a pair. The token
        /// chain in them is the initial one; a chain only advances through the
        /// pair's token exchange.
        public let rankRecords: [Data]
        /// Frames whose stage 0 residual failed the sender's ownership check as
        /// produced, and the first of them. A pair fails at the first such frame.
        public let unownedResidualFrames: [Int]
        public let firstUnownedResidual: UnownedResidual?

        public let stageLoadSeconds: [Double]
        public let loadedTensorBytes: [Int]
        /// Sum of the prefill frames' forward times, through the first selection.
        public let prefillNanoseconds: UInt64
        /// Sum of the decode frames' forward times (`selectedTokenIDs.count - 1` frames).
        public let decodeNanoseconds: UInt64
        /// Request state construction to retirement, including every row capture.
        public let requestWallNanoseconds: UInt64

        public let activeBytesBefore: Int
        public let activeBytesLoaded: Int
        public let peakBytes: Int
        public let activeBytesAfterRelease: Int
        public let cacheBytesAfterRelease: Int
        public let stageModelsReleased: [Bool]
    }

    private static let matrixPath = "/var/empty/darkbloom-staged-reference.matrix.json"
    private static let matrix = Data(#"[[null,"staged-reference-0"],["staged-reference-1",null]]"#.utf8)
    private static let nativeNames = ["JACCL_RANK", "MLX_RANK", "JACCL_IBV_DEVICES", "MLX_IBV_DEVICES",
        "JACCL_COORDINATOR", "MLX_JACCL_COORDINATOR", "JACCL_RING", "MLX_JACCL_RING"]

    /// Everything a run produces that is not a plain value stays inside this
    /// function, so the release at the end can be checked against weak references.
    public static func run(modelDirectory: URL, stageCut: Int, request value: Request,
                           deadlineUptimeNanoseconds: UInt64, topCount: Int = 4) throws -> Result {
        guard (2...16).contains(topCount) else { throw ProbeError("Reference top count must be 2...16") }
        let processEnvironment = ProcessInfo.processInfo.environment
        guard nativeNames.allSatisfy({ processEnvironment[$0] == nil }) else {
            throw ProbeError("Staged reference refuses a cluster transport environment; it creates no collective")
        }
        guard let specification = QwenDenseRegisteredSpecification.all.first(where: { $0.model == .qwen35NineB }) else {
            throw ProbeError("Registered 9B specification is unavailable")
        }
        let identity = ClusterWorkerIdentity(membershipEpoch: UUID(),
            modelID: QwenRegisteredDenseModel.qwen35NineB.rawValue,
            artifactSHA256: specification.artifactSHA256,
            configurationSHA256: specification.configurationSHA256,
            peers: (0...1).map {
                ClusterWorkerPeer(id: "staged-reference-\($0)", buildSHA256: String(repeating: "0", count: 64))
            })
        let configBytes = try BoundedProbeInput.data(modelDirectory.appendingPathComponent("config.json"),
                                                    maximumBytes: 1_048_576)
        let manifestBytes = try BoundedProbeInput.data(modelDirectory.appendingPathComponent("manifest.json"),
                                                      maximumBytes: 4_194_304)
        // Each rank is admitted exactly as its worker would be. The device
        // matrix is the only synthetic input, and nothing opens it.
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
                read: { url, limit in
                    url.path == matrixPath ? matrix : try BoundedProbeInput.data(url, maximumBytes: limit)
                })
        }
        let plan = admissions[0].plan
        guard plan.fingerprint == admissions[1].plan.fingerprint,
              admissions[0].arithmeticSHA256 == admissions[1].arithmeticSHA256 else {
            throw ProbeError("Staged reference admissions disagree on Plan or arithmetic")
        }
        // The worker's own request admission, including the profile bounds.
        let request = try admissions[0].request(.init(profileID: admissions[0].profile.identifier,
                promptTokenIDs: value.promptTokenIDs, stopTokenIDs: value.stopTokenIDs,
                outputCount: value.outputCount, chunkSize: value.chunkSize,
                deadlineUptimeNanoseconds: deadlineUptimeNanoseconds, capacityLimitBytes: 1),
            id: value.requestID, now: DispatchTime.now().uptimeNanoseconds)

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
                // The worker's allocator policy, set before any model storage exists.
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
                    throw ProbeError("Staged reference stages did not load matching verified commitments")
                }
                let loadedBytes = Memory.snapshot().activeMemory
                // Each rank's named request allowance, checked live as the worker does.
                let allowances = try (0...1).map {
                    try QwenResidentRequestAllowance.derive(profile: stages[$0].profile, plan: plan, rank: $0,
                        maximumTokens: request.maximumTokens, chunkSize: min(request.chunkSize, request.promptCount),
                        bound: QwenResidentResourceEnvironment.allocationBound)
                }
                var lastResourceCheck: UInt64 = 0
                var captures: [QwenGenerationDiagnosticCapture] = []
                func live() throws {
                    try checked()
                    let now = DispatchTime.now().uptimeNanoseconds
                    if lastResourceCheck == 0 || now - lastResourceCheck >= 250_000_000 {
                        for allowance in allowances { try allowance.requireLive() }
                        lastResourceCheck = DispatchTime.now().uptimeNanoseconds
                    }
                    for capture in captures { try capture.resources.requireLive() }
                    try checked()
                }
                try live()
                // Each rank's capture, exactly as a recording worker reserves and
                // drives it: the same resource binding, row and state capture and
                // record type, with no collective between the ranks.
                captures = try (0...1).map { rank in
                    QwenGenerationDiagnosticCapture(request: request, rank: rank,
                        resources: try QwenGenerationDiagnosticResources(loaded: stages[rank].loaded,
                            profile: stages[rank].profile, plan: plan, request: request, rank: rank,
                            requestAllowance: allowances[rank]))
                }

                let requestStarted = DispatchTime.now().uptimeNanoseconds
                for rank in 0...1 {
                    sessions.append(try QwenLayerStageSession(stage: stages[rank].loaded, plan: plan,
                                                              generationRequest: request))
                }
                var tokens: [Int] = [], steps: [Step] = []
                var finalLogits: QwenRecordedLogits?
                var completedFrames = 0
                var prefill: UInt64 = 0, decode: UInt64 = 0
                var reason: QwenLayerStageGenerationFinishReason?
                var unownedFrames: [Int] = []
                var firstUnowned: UnownedResidual?
                for sequence in 0..<request.forwardCount {
                    let frame = try request.frame(sequence: sequence)
                    try autoreleasepool {
                        try live()
                        let frameStarted = DispatchTime.now().uptimeNanoseconds
                        let ids: [Int]
                        if frame.phase == .prefill {
                            ids = Array(request.promptTokenIDs[frame.tokenOffset..<(frame.tokenOffset + frame.tokenCount)])
                        } else {
                            guard let previous = tokens.last else { throw ProbeError("Staged reference decode lacks a selected token") }
                            ids = [previous]
                        }
                        func forward(_ rank: Int, _ incoming: QwenLayerStageBoundary?) throws -> QwenLayerStageOutput {
                            frame.phase == .prefill
                                ? try sessions[rank].prefillChunk(ids, offset: frame.tokenOffset,
                                    final: frame.finalPromptChunk, incoming: incoming, check: live)
                                : try sessions[rank].decode(ids[0], offset: frame.tokenOffset, incoming: incoming, check: live)
                        }
                        guard case .hidden(let produced) = try forward(0, nil) else {
                            throw ProbeError("Staged reference stage 0 did not return a residual")
                        }
                        // Rank 0's sender applies this check to the residual as
                        // produced, before it sends it. Recorded, not enforced: the
                        // copy below gives stage 1 an owned array either way.
                        let senderDType = stages[0].loaded.activationDType
                        func senderAccepts() -> Bool {
                            (try? produced.validateOwnedArray(tokens: frame.tokenCount,
                                hidden: request.profile.hiddenSize, dtype: senderDType)) != nil
                        }
                        if !senderAccepts() {
                            unownedFrames.append(frame.sequence)
                            let info = try produced.array.evaluatedBufferInfo()
                            let bound = try Memory.allocationFootprintUpperBound(byteCount: produced.array.nbytes)
                            Stream.gpu.synchronize()
                            if firstUnowned == nil, let info {
                                firstUnowned = .init(frameSequence: frame.sequence, phase: frame.phase.rawValue,
                                    tokenCount: frame.tokenCount, byteCount: produced.array.nbytes,
                                    allocatedBytes: info.allocatedBytes, allocationBound: bound,
                                    dataOffset: info.dataOffset, dataElements: info.dataElements,
                                    elementCount: produced.array.size, isUnique: info.isUnique,
                                    isRowContiguous: info.isRowContiguous, ownedAfterGPUSynchronize: senderAccepts())
                            }
                        }
                        // The pair moves these bytes over the link into a fresh
                        // allocation. Here they are copied into one, and the copy
                        // is checked byte for byte before stage 1 consumes it.
                        let incoming = try produced.ownedCopy(check: live)
                        let output = try forward(1, incoming)
                        guard sessions[0].committedTokens == frame.tokenOffset + frame.tokenCount,
                              sessions[1].committedTokens == sessions[0].committedTokens else {
                            throw ProbeError("Staged reference stages committed different frontiers")
                        }
                        completedFrames += 1
                        let row: MLXArray
                        switch output {
                        case .evaluationHandle where frame.phase == .prefill && !frame.finalPromptChunk:
                            prefill += DispatchTime.now().uptimeNanoseconds - frameStarted
                            return
                        case .logits(let logits) where frame.finalPromptChunk || frame.phase == .decode: row = logits
                        default: throw ProbeError("Staged reference stage 1 output does not match its frame")
                        }
                        let token = try QwenLayerStageGenerationSelection.token(row, request: request, check: live)
                        let elapsed = DispatchTime.now().uptimeNanoseconds - frameStarted
                        if frame.phase == .prefill { prefill += elapsed } else { decode += elapsed }
                        // Not timed: the complete row is copied to the CPU.
                        let captured = try QwenRecordedLogits(row, vocabularySize: request.profile.vocabularySize, check: live)
                        let top = topValues(captured.record.values, count: topCount)
                        guard top.indices.first == token else {
                            throw ProbeError("Staged reference native selection differs from the captured row")
                        }
                        steps.append(.init(ordinal: tokens.count, frameSequence: frame.sequence,
                            committedTokens: frame.tokenOffset + frame.tokenCount, tokenID: token,
                            topTokenIDs: top.indices, topLogits: top.values, maximumTieCount: top.tieCount,
                            rowSHA256: captured.record.logicalBytesSHA256, forwardNanoseconds: elapsed))
                        tokens.append(token); finalLogits = captured
                        if request.stopTokenIDs.contains(token) { reason = .eos }
                        else if tokens.count == request.outputCount { reason = .length }
                        if reason != nil {
                            // The final frame: rank 1 owns the row, rank 0 records none.
                            try captures[0].captureFinalRow(nil, frame: frame, tokenID: token, check: live)
                            try captures[1].captureFinalRow(row, frame: frame, tokenID: token, check: live)
                        }
                    }
                    if reason != nil { break }
                }
                guard let reason, let last = tokens.last, let finalLogits else {
                    throw ProbeError("Staged reference ended without a selected-token completion")
                }
                let committed = sessions[1].committedTokens
                try live()
                let snapshots = try sessions.map { try $0.snapshot(includeBytes: false, check: live) }
                let state = try QwenRecordedState(snapshots: snapshots, plan: plan, committedTokens: committed)
                // Replays the schedule against the selected history, then snapshots
                // this rank's state before its request state retires.
                for rank in 0...1 {
                    try captures[rank].captureState(session: sessions[rank], stage: plan.stages[rank],
                        selectedTokenIDs: tokens, completedFrames: completedFrames, committedTokens: committed,
                        reason: reason, check: live)
                }
                for session in sessions {
                    try session.finishGeneration(reason, selectedTokenCount: tokens.count, lastTokenID: last)
                    guard session.isClosed, !session.isFailed else {
                        throw ProbeError("Staged reference request state failed retirement")
                    }
                }
                let requestWall = DispatchTime.now().uptimeNanoseconds - requestStarted
                let identities = sessions.map(\.identity)
                let source = try QwenLayerStageWireSourceIdentity(
                    sourceConfigurationSHA256: receipts[0].sourceConfigurationSHA256,
                    artifactAggregateSHA256: receipts[0].verifiedAggregateSHA256,
                    storageCommitmentSHA256: receipts[0].storageCommitmentSHA256,
                    planFingerprint: plan.fingerprint, producerStageFingerprint: plan.stages[0].fingerprint)
                let agreement = try QwenLayerStageGenerationAgreement(request: request,
                    membershipEpoch: identity.membershipEpoch, source: source,
                    consumerStageFingerprint: plan.stages[1].fingerprint,
                    rankBuildSHA256: identity.peers.map(\.buildSHA256), numericalPolicySHA256: admissions[0].arithmeticSHA256)
                // Published only after both request states have retired, as in the pair.
                let rankRecords = try (0...1).map { rank -> Data in
                    let execution = QwenLayerStageGenerationResult(agreementFingerprint: agreement.fingerprint,
                        membershipEpoch: agreement.descriptor.membershipEpoch, identity: identities[rank],
                        selectedTokenIDs: tokens, tokenChainSHA256: agreement.initialTokenChainSHA256,
                        completedFrames: completedFrames, committedTokens: committed, finishReason: reason)
                    return try captures[rank].finish(execution: execution, agreement: agreement,
                                                     stage: plan.stages[rank]).encoded()
                }
                captures.removeAll()
                let profile = admissions[0].profile
                let loadedTensorBytes = receipts.map(\.loadedTensorBytes)
                let layers = stages.reduce(0) { $0 + $1.loaded.layerCount }
                let peak = Memory.snapshot().peakMemory

                // Release in the order the resident runtime uses: request state,
                // then the stages, both streams drained, cached buffers returned.
                sessions.removeAll()
                stages.removeAll()
                try settle()
                Memory.clearCache()
                try settle()
                let after = Memory.snapshot()
                return Result(requestFingerprint: request.fingerprint, profileID: profile.identifier,
                    profileFingerprint: profile.fingerprint, planSHA256: plan.fingerprint,
                    stageSHA256: plan.stages.map(\.fingerprint),
                    artifactSHA256: identities[0].artifactAggregateSHA256,
                    configurationSHA256: identities[0].sourceConfigurationSHA256,
                    storageCommitmentSHA256: identities[0].storageCommitmentSHA256,
                    arithmeticContract: admissions[0].arithmetic.contract,
                    arithmeticSHA256: admissions[0].arithmeticSHA256, stageCut: stageCut, layerCount: layers,
                    selectedTokenIDs: tokens, finishReason: reason.rawValue, completedFrames: completedFrames,
                    committedTokens: committed, steps: steps,
                    finalLogitsShape: finalLogits.record.shape, finalLogitsDType: finalLogits.record.dtype,
                    finalLogitsByteCount: finalLogits.record.byteCount,
                    finalLogitsSHA256: finalLogits.record.logicalBytesSHA256, finalLogits: finalLogits.record.values,
                    stateEntries: state.entries.map {
                        .init(globalLayerIndex: $0.globalLayerIndex, component: $0.component, shape: $0.shape,
                              dtype: $0.dtype, byteCount: $0.byteCount, sha256: $0.sha256)
                    }, stateSHA256: state.fingerprint, rankRecords: rankRecords,
                    unownedResidualFrames: unownedFrames, firstUnownedResidual: firstUnowned,
                    stageLoadSeconds: loadSeconds, loadedTensorBytes: loadedTensorBytes,
                    prefillNanoseconds: prefill, decodeNanoseconds: decode, requestWallNanoseconds: requestWall,
                    activeBytesBefore: before, activeBytesLoaded: loadedBytes, peakBytes: peak,
                    activeBytesAfterRelease: after.activeMemory, cacheBytesAfterRelease: after.cacheMemory,
                    stageModelsReleased: [retired0 == nil, retired1 == nil])
            } catch {
                var primary: Error = error
                // Prefer a recorded native fault over a secondary Swift error.
                do { try nativeError.check() } catch { primary = error }
                for session in sessions { try? session.cancel() }
                sessions.removeAll(); stages.removeAll()
                Stream.gpu.synchronize(); Stream.cpu.synchronize()
                Memory.clearCache()
                throw primary
            }
        }
    }

    /// The `count` largest values, descending, ties broken by lower index, and
    /// how many entries equal the maximum.
    static func topValues(_ values: [Float], count: Int) -> (indices: [Int], values: [Float], tieCount: Int) {
        var best: [(index: Int, value: Float)] = []
        best.reserveCapacity(count + 1)
        for (index, value) in values.enumerated() {
            if best.count == count, let last = best.last, value <= last.value { continue }
            let position = best.firstIndex(where: { value > $0.value }) ?? best.count
            best.insert((index, value), at: position)
            if best.count > count { best.removeLast() }
        }
        let maximum = best.first?.value
        let ties = maximum.map { top in values.reduce(0) { $0 + ($1 == top ? 1 : 0) } } ?? 0
        return (best.map(\.index), best.map(\.value), ties)
    }
}
