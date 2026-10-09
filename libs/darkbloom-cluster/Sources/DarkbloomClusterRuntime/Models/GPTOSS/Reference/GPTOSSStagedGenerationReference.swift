import DarkbloomClusterProtocol
import Foundation
import MLX
import MLXNN

/// One Mac, both stages of the registered GPT-OSS artifact, no collective. It
/// runs the same staged request a two-Mac pair runs: stage 0 produces the
/// residual for a frame, the residual is physically copied, stage 1 consumes
/// the copy and, on the final prompt chunk and every decode frame, the pair's
/// own greedy selection picks the token. Loader, admission, sessions, frame
/// schedule and selection are the worker's; only the transfer between stages
/// differs. Its result and service types are the dense reference's, so the
/// same reports, comparator and solo driver read both families.
///
/// It is a comparison reference, not a serving path: it holds both stages in
/// one process, copies every target row to the CPU, and runs each rank's
/// recording capture so the records a recording worker would write exist for
/// this history too.
public enum GPTOSSStagedGenerationReference {
    public typealias Request = QwenStagedGenerationReference.Request
    public typealias Result = QwenStagedGenerationReference.Result
    public typealias ServiceReady = QwenStagedGenerationReference.ServiceReady
    public typealias ServiceCompletion = QwenStagedGenerationReference.ServiceCompletion
    public typealias ServiceRelease = QwenStagedGenerationReference.ServiceRelease

    public static func handles(configuration: Data) -> Bool {
        GPTOSSRegisteredSpecification.handles(configuration: configuration)
    }

    private static func admit(modelDirectory: URL, stageCut: Int, deadline: UInt64,
                              label: String) throws -> (admissions: [GPTOSSResidentAdmission], identity: ClusterWorkerIdentity) {
        let configBytes = try BoundedProbeInput.data(modelDirectory.appendingPathComponent("config.json"),
                                                    maximumBytes: 1_048_576)
        let identity = GPTOSSResidentAdmission.localIdentity(
            try GPTOSSRegisteredSpecification.specification(configuration: configBytes), label: label)
        let admissions = try (0...1).map {
            try GPTOSSResidentAdmission.local(modelDirectory: modelDirectory, rank: $0, stageCut: stageCut,
                deadlineUptimeNanoseconds: deadline, identity: identity, label: label,
                allocatorPolicy: .disableFreedBufferCache)
        }
        guard admissions[0].plan.fingerprint == admissions[1].plan.fingerprint,
              admissions[0].arithmeticSHA256 == admissions[1].arithmeticSHA256 else {
            throw ProbeError("Staged reference admissions disagree on Plan or arithmetic")
        }
        return (admissions, identity)
    }

    /// The worker's allocator policy, the verified source and both stages.
    /// The stages go only into the caller's own array: a second reference
    /// here would keep a model alive past the caller's release.
    private static func load(_ admissions: [GPTOSSResidentAdmission], modelDirectory: URL,
                             into stages: inout [LoadedGPTOSSLayerStage],
                             checked: () throws -> Void, settle: () throws -> Void,
                             constructed: (Int, Module) -> Void) throws -> (seconds: [Double], before: Int) {
        try QwenResidentAllocatorPolicy.disableFreedBufferCache.configure(
            setCacheLimit: { Memory.cacheLimit = $0 }, check: checked)
        try settle()
        let before = Memory.snapshot().activeMemory
        var seconds: [Double] = []
        for rank in 0...1 {
            let started = DispatchTime.now().uptimeNanoseconds
            try autoreleasepool {
                // Each rank verifies the artifact for itself, as its worker does.
                let source = try prepareGPTOSSResidentSource(directory: modelDirectory,
                    configuration: admissions[rank].configBytes, manifest: admissions[rank].manifestBytes,
                    specification: admissions[rank].specification, plan: admissions[rank].plan, check: checked)
                stages.append(try loadGPTOSSResidentStage(source: source, stageIndex: rank, check: checked,
                                                          constructed: { constructed(rank, $0) }))
            }
            try settle()
            seconds.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9)
        }
        try QwenResidentAllocatorPolicy.disableFreedBufferCache.prepareReady(
            synchronize: { Stream.gpu.synchronize(); Stream.cpu.synchronize() },
            snapshot: {
                let now = Memory.snapshot()
                return .init(activeBytes: now.activeMemory, cachedBytes: now.cacheMemory, peakBytes: now.peakMemory)
            }, clearCache: { Memory.clearCache() }, check: checked)
        let receipts = stages.map(\.receipt)
        guard receipts[0].storageCommitmentSHA256 == receipts[1].storageCommitmentSHA256,
              receipts[0].verifiedAggregateSHA256 == receipts[1].verifiedAggregateSHA256,
              receipts[0].sourceParameterLayoutSHA256 == receipts[1].sourceParameterLayoutSHA256 else {
            throw ProbeError("Staged reference stages did not load matching verified commitments")
        }
        return (seconds, before)
    }

    /// Everything a run produces that is not a plain value stays inside this
    /// function, so the release at the end can be checked against weak references.
    public static func run(modelDirectory: URL, stageCut: Int, request value: Request,
                           deadlineUptimeNanoseconds: UInt64, topCount: Int = 4) throws -> Result {
        guard (2...16).contains(topCount) else { throw ProbeError("Reference top count must be 2...16") }
        let (admissions, identity) = try admit(modelDirectory: modelDirectory, stageCut: stageCut,
            deadline: deadlineUptimeNanoseconds, label: "staged-reference")
        let plan = admissions[0].plan
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

        var stages: [LoadedGPTOSSLayerStage] = []
        weak var retired0: Module?
        weak var retired1: Module?
        var sessions: [GPTOSSLayerStageSession] = []
        return try MLX.withError { nativeError in
            func checked() throws { try nativeError.check(); try control.check(); try nativeError.check() }
            func settle() throws {
                Stream.gpu.synchronize(); Stream.cpu.synchronize()
                try nativeError.check()
            }
            do {
                let loaded = try load(admissions, modelDirectory: modelDirectory, into: &stages,
                    checked: checked, settle: settle,
                    constructed: { rank, model in if rank == 0 { retired0 = model } else { retired1 = model } })
                let receipts = stages.map(\.receipt)
                let loadedBytes = Memory.snapshot().activeMemory
                // Each rank's named request allowance and capture, checked live as a recording worker does.
                let allowances = try (0...1).map {
                    try GPTOSSResidentRequestAllowance.derive(plan: plan, rank: $0,
                        maximumTokens: request.maximumTokens, chunkSize: min(request.chunkSize, request.promptCount))
                }
                let budgets = try (0...1).map {
                    try QwenGenerationDiagnosticBudget.derive(rank: $0, vocabularySize: request.profile.vocabularySize,
                        activationDType: request.profile.activationDType,
                        requestReservedBytes: allowances[$0].reservedBytes,
                        bound: QwenResidentResourceEnvironment.allocationBound)
                }
                var lastResourceCheck: UInt64 = 0
                func live() throws {
                    try checked()
                    let now = DispatchTime.now().uptimeNanoseconds
                    if lastResourceCheck == 0 || now - lastResourceCheck >= 250_000_000 {
                        for rank in 0...1 {
                            try allowances[rank].requireLive(additionalNativeBytes: budgets[rank].extraNativeBytes,
                                                             additionalHostBytes: budgets[rank].extraHostBytes)
                        }
                        lastResourceCheck = DispatchTime.now().uptimeNanoseconds
                    }
                    try checked()
                }
                try live()
                let captures = try (0...1).map {
                    try GPTOSSGenerationRecording(request: request, rank: $0, budget: budgets[$0])
                }
                defer { captures.forEach { $0.discard() } }

                let requestStarted = DispatchTime.now().uptimeNanoseconds
                for rank in 0...1 {
                    sessions.append(try GPTOSSLayerStageSession(stage: stages[rank], plan: plan, generationRequest: request))
                }
                var tokens: [Int] = [], steps: [QwenStagedGenerationReference.Step] = []
                var finalLogits: QwenRecordedLogits?
                var completedFrames = 0
                var prefill: UInt64 = 0, decode: UInt64 = 0
                var reason: QwenLayerStageGenerationFinishReason?
                var unownedFrames: [Int] = []
                var firstUnowned: QwenStagedGenerationReference.UnownedResidual?
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
                        let senderDType = stages[0].activationDType
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
                        let top = QwenStagedGenerationReference.topValues(captured.record.values, count: topCount)
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
                // Replays the schedule against the selected history, then records
                // each rank's state before its request state retires.
                for rank in 0...1 {
                    try captures[rank].captureState(session: sessions[rank], selectedTokenIDs: tokens,
                        completedFrames: completedFrames, committedTokens: committed, reason: reason, check: live)
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
                let records = try (0...1).map { rank -> QwenGenerationDiagnosticEvidence in
                    let execution = QwenLayerStageGenerationResult(agreementFingerprint: agreement.fingerprint,
                        membershipEpoch: agreement.descriptor.membershipEpoch, identity: identities[rank],
                        selectedTokenIDs: tokens, tokenChainSHA256: agreement.initialTokenChainSHA256,
                        completedFrames: completedFrames, committedTokens: committed, finishReason: reason)
                    return try captures[rank].finish(execution: execution, agreement: agreement, stage: plan.stages[rank])
                }
                let entries = records.flatMap(\.stateEntries)
                    .sorted { ($0.globalLayerIndex, $0.component) < ($1.globalLayerIndex, $1.component) }
                guard Set(entries.map(\.key)).count == entries.count, entries.count == plan.layers * 2 else {
                    throw ProbeError("Staged reference stages recorded overlapping or incomplete state")
                }
                let profile = admissions[0].profile
                let loadedTensorBytes = receipts.map(\.loadedTensorBytes)
                let layers = stages.reduce(0) { $0 + $1.layerCount }
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
                    stateEntries: entries.map {
                        .init(globalLayerIndex: $0.globalLayerIndex, component: $0.component, shape: $0.shape,
                              dtype: $0.dtype, byteCount: $0.byteCount, sha256: $0.sha256)
                    }, stateSHA256: gptossStateFingerprint(entries, committedTokens: committed),
                    rankRecords: try records.map { try $0.encoded() },
                    unownedResidualFrames: unownedFrames, firstUnownedResidual: firstUnowned,
                    stageLoadSeconds: loaded.seconds, loadedTensorBytes: loadedTensorBytes,
                    prefillNanoseconds: prefill, decodeNanoseconds: decode, requestWallNanoseconds: requestWall,
                    activeBytesBefore: loaded.before, activeBytesLoaded: loadedBytes, peakBytes: peak,
                    activeBytesAfterRelease: after.activeMemory, cacheBytesAfterRelease: after.cacheMemory,
                    stageModelsReleased: [retired0 == nil, retired1 == nil], resourceAdmission: .current,
                    handoff: nil)
            } catch {
                var primary: Error = error
                // Prefer a recorded native fault over a secondary Swift error.
                do { try nativeError.check() } catch { primary = error }
                for session in sessions { try? session.cancel() }
                sessions.removeAll(); stages.removeAll()
                Stream.gpu.synchronize(); Stream.cpu.synchronize()
                Memory.clearCache()
                // What this process still holds after releasing a failed run.
                let after = Memory.snapshot()
                throw QwenResidentReleasedFailure(failure: String(describing: primary),
                    activeBytesAfterRelease: after.activeMemory, cacheBytesAfterRelease: after.cacheMemory,
                    modelsReleased: [retired0 == nil, retired1 == nil], resourceAdmission: .current)
            }
        }
    }

    /// One Mac, both stages, no collective and no capture: the staged request
    /// as a single Mac serves it, for timing by a clock outside this process.
    /// Stages are loaded once; requests then run one after another, each
    /// reporting its tokens as they are selected. `next` blocks until the next
    /// request and returns nil to shut down. Stage 0's residual is handed
    /// straight to stage 1 when it is an owned compact array and copied bit
    /// for bit otherwise. Nothing is recorded; correctness is `run`'s job.
    public static func serve(modelDirectory: URL, stageCut: Int, deadlineUptimeNanoseconds: UInt64,
                             ready: (ServiceReady) throws -> Void, next: () throws -> Request?,
                             token: (_ ordinal: Int, _ tokenID: Int) throws -> Void,
                             finished: (ServiceCompletion) throws -> Void) throws -> ServiceRelease {
        let (admissions, _) = try admit(modelDirectory: modelDirectory, stageCut: stageCut,
            deadline: deadlineUptimeNanoseconds, label: "staged-service")
        let plan = admissions[0].plan
        let control = QwenResidentControl(deadline: deadlineUptimeNanoseconds)
        try QwenResidentProcessLease.shared.acquire()
        defer { QwenResidentProcessLease.shared.release() }
        try control.check()
        try QwenResidentResourceEnvironment.require()

        var stages: [LoadedGPTOSSLayerStage] = []
        weak var retired0: Module?
        weak var retired1: Module?
        var sessions: [GPTOSSLayerStageSession] = []
        return try MLX.withError { nativeError in
            func checked() throws { try nativeError.check(); try control.check(); try nativeError.check() }
            func settle() throws {
                Stream.gpu.synchronize(); Stream.cpu.synchronize()
                try nativeError.check()
            }
            do {
                let loaded = try load(admissions, modelDirectory: modelDirectory, into: &stages,
                    checked: checked, settle: settle,
                    constructed: { rank, model in if rank == 0 { retired0 = model } else { retired1 = model } })
                try ready(.init(stageLoadSeconds: loaded.seconds, activeBytesBefore: loaded.before,
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
                    let allowances = try (0...1).map {
                        try GPTOSSResidentRequestAllowance.derive(plan: plan, rank: $0,
                            maximumTokens: request.maximumTokens, chunkSize: min(request.chunkSize, request.promptCount))
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
                        sessions.append(try GPTOSSLayerStageSession(stage: stages[rank], plan: plan, generationRequest: request))
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
                            switch try forward(1, incoming) {
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
