import DarkbloomClusterProtocol
import DarkbloomClusterSecurity
import Foundation
import MLX
import MLXLMCommon
import MLXNN

/// The worker's resident owner for `tensor_parallel_v1` on the dense Qwen
/// rows (9B, 27B): both ranks hold a share of every layer (heads, key/value
/// heads, MLP channels and vocabulary rows, `QwenTensorParallelPlan`), run
/// every prefill chunk and decode step together, and sum each row-parallel
/// projection's partials with the sealed all-sum inside the lazy graph: every
/// partial crosses the cable as an AES-256-GCM frame under direction keys the
/// pinned data-plane exchange (S16) derived for this session and load
/// agreement, rekeyed by count and bytes; a frame that does not authenticate
/// ends the evaluation on both ranks.
///
/// The same contract as `QwenResidentRuntime` for the worker's executor:
/// synchronous, one request at a time, cancel from the control thread only,
/// an enclosing process deadline required (a blocked collective cannot be
/// interrupted cooperatively).
///
/// Generation: a greedy request's token is the distributed argmax (one small
/// sealed reduction per step, both ranks learn the token); a sampled
/// request's whole-vocabulary logits are gathered to every rank (exact: each
/// rank adds zeros outside its rows) and rank 0 draws with the product's
/// sampler (`QwenStageTokenSampler`), then makes the token known to rank 1 in
/// one small sealed reduction. Each step's reduction also carries every
/// rank's stop flag, so a client stop, a cancellation or a deadline on either
/// rank ends both after the same step with no extra exchange. Stop tokens and
/// the output count are known to both ranks and end both at once.
///
/// Prompt prefixes: each rank keeps its own heads' state at chunk boundaries
/// (`QwenTensorParallelPrefixCache`); a request restores the longest boundary
/// BOTH ranks hold (one sealed vote), or neither restores.
public final class QwenTensorParallelResidentRuntime {
    let admission: QwenResidentAdmission
    let control: QwenResidentControl
    let collective: Collective
    let group: QwenTensorParallelGroup
    let codec: QwenTensorParallelSealCodec?
    let lifecycle = QwenLayerStageResidentLifecycle()
    let loadAgreement: String
    private let operation = NSLock()
    private let keepWarm = ClusterKeepWarm()
    private var model: QwenTensorParallelModel?
    private let profile: QwenRegisteredDenseModelProfile
    private let baseReady: ClusterWorkerReady
    private var reservation: Reserved?
    private var processLeaseOwned = true
    public let shares: [Int]
    public let receipt: String
    /// What this rank measured of the link at load (`QwenTensorParallelLinkProbe`).
    public let linkProbe: ClusterWorkerLinkProbe?
    let prefix: QwenTensorParallelPrefixCache

    struct Reserved {
        let request: QwenLayerStageGenerationRequest
        let allowance: QwenResidentRequestAllowance
        let extraNativeBytes: Int
        let deadline: UInt64
    }

    /// Bound into the load agreement besides the mode's terms: the plan and
    /// each rank's share weight (ranks with other shares would sum partials of
    /// overlapping or missing heads without any mismatched shape).
    static func loadAgreementFields(shares: [Int]) -> [String] {
        ["qwen-tensor-parallel-shares-v1", shares.map(String.init).joined(separator: ":")]
    }

    public static func load(_ configuration: QwenResidentLoadConfiguration, shares: [Int] = [1, 1],
                            qualification: QwenResidentQualificationSwitches = .refused,
                            dataPlane credential: ClusterDataPlaneCredential? = nil,
                            prefixSSDKey: Data? = nil) throws -> QwenTensorParallelResidentRuntime {
        let environment = ProcessInfo.processInfo.environment
        try qualification.admit(environment: environment)
        guard shares.count == 2, shares.allSatisfy({ (1...64).contains($0) }) else {
            throw ProbeError("Tensor-parallel shares are two weights of 1...64")
        }
        let directory = configuration.modelDirectory
        let any = try LayerStageResidentFamily.admission(configuration: configuration,
            configBytes: BoundedProbeInput.data(directory.appendingPathComponent("config.json"), maximumBytes: 1_048_576),
            manifestBytes: BoundedProbeInput.data(directory.appendingPathComponent("manifest.json"), maximumBytes: 4_194_304),
            environment: environment, now: DispatchTime.now().uptimeNanoseconds,
            read: { try BoundedProbeInput.data($0, maximumBytes: $1) })
        guard let admission = any as? QwenResidentAdmission,
              admission.supportedGenerationModes.contains(.tensorParallel) else {
            throw ProbeError("Generation mode tensor_parallel_v1 is not in the resident row of \(any.runtimeModelID)")
        }
        let control = QwenResidentControl(deadline: configuration.deadlineUptimeNanoseconds, lease: configuration.lease)
        try QwenResidentProcessLease.shared.acquire()
        var loadedModel: QwenTensorParallelModel?
        weak var retired: QwenTensorParallelModel?
        do {
            try control.check(); try QwenResidentResourceEnvironment.require()
            try admission.jaccl.requireUnchanged(environment: environment, read: { try BoundedProbeInput.data($0, maximumBytes: $1) })
            if configuration.allocatorPolicy == .disableFreedBufferCache {
                try MLX.withError { nativeError in
                    func checked() throws { try nativeError.check(); try control.check(); try nativeError.check() }
                    do {
                        try configuration.allocatorPolicy.configure(setCacheLimit: { Memory.cacheLimit = $0 }, check: checked)
                    } catch { try nativeError.check(); throw error }
                }
            }
            // RDMA only: the sealed all-sum runs on the JACCL group itself.
            let collective = try Collective(transport: .jaccl)
            try admission.jaccl.requireUnchanged(environment: environment, read: { try BoundedProbeInput.data($0, maximumBytes: $1) })
            try admission.jaccl.requireInitialized(rank: collective.rank, worldSize: collective.size, transport: collective.transport)
            let mode = ClusterGenerationMode.tensorParallel
            // The prefix cache votes in a reduction of its own: both ranks must have it on, or both off.
            let prefixEnabled = QwenStagePrefixCache.fromEnvironment(environment).enabled
            let fields = mode.loadAgreementFields + loadAgreementFields(shares: shares)
                + ["qwen-tensor-parallel-prefix-v1", prefixEnabled ? "on" : "off"]
                + (credential == nil ? [] : ClusterDataPlaneAgreement.loadAgreementFields)
            let loadAgreement = sha256(try canonicalJSONData([try admission.loadAgreementFingerprint()] + fields))
            if let credential {
                try ClusterDataPlaneAgreement.establish(collective: collective, credential: credential,
                    loadAgreement: loadAgreement, tamper: nil, tensorParallelSeal: true, check: { try control.check() })
            }
            let group = try QwenTensorParallelGroup(collective: collective)
            var codec: QwenTensorParallelSealCodec?
            if credential != nil {
                let installed = try QwenTensorParallelSealCodec.product(collective: collective, scope: Data(loadAgreement.utf8))
                try installed.install()
                group.sealed = installed; codec = installed
            }
            var probe: ClusterWorkerLinkProbe?
            var shardReceipt: QwenTensorParallelShardReceipt?
            var source: QwenRegisteredDenseModelProfile?
            let capacity = try MLX.withError { nativeError -> Int in
                func checked() throws { try nativeError.check(); try control.check(); try nativeError.check() }
                _ = try requireQwenLongPrefillReadinessDigest(collective: collective,
                    material: { .residentLoadIntent(agreementFingerprint: loadAgreement) },
                    disagreementMessage: "Tensor-parallel load membership/source/plan/shares differ",
                    scope: .session(.loadAgreement, "resident-load-intent"), check: checked)
                // The link, measured as this mode uses it, before any weight is read.
                probe = try QwenTensorParallelLinkProbe.measure(collective: collective, group: group,
                    hiddenSize: admission.profile.hiddenSize, chunkTokens: admission.profile.maximumChunkTokens, check: checked)
                if let probe { log(QwenTensorParallelLinkProbe.line(probe, rank: collective.rank)) }
                let value = try autoreleasepool {
                    try QwenTensorParallelVerifiedLoad.load(admission, rank: collective.rank, shares: shares,
                        reduction: group, check: checked)
                }
                retired = value.model; loadedModel = value.model; shardReceipt = value.receipt; source = value.profile
                let loadedIdentity = sha256(try canonicalJSONData([loadAgreement, value.receipt.verifiedAggregateSHA256,
                    value.receipt.storageCommitmentSHA256, value.receipt.planName]))
                _ = try requireQwenLongPrefillReadinessDigest(collective: collective,
                    material: { .residentLoaded(agreementFingerprint: loadedIdentity) },
                    disagreementMessage: "Tensor-parallel peers did not load matching verified commitments",
                    scope: .session(.loadedReady, "resident-loaded"), check: checked)
                let bufferCacheBytes = configuration.allocatorPolicy == .disableFreedBufferCache
                    ? QwenTensorParallelLaunch.freedBufferCacheBytes(allocatorHeadroomBytes: QwenDenseStageLoadPolicy.allocatorHeadroomBytes)
                    : Memory.cacheLimit
                log("darkbloom-tensor-parallel-load-v1 rank=\(collective.rank) plan=\(value.receipt.planName)"
                    + " shares=\(shares.map(String.init).joined(separator: "-")) shard_bytes=\(value.receipt.shardBytes)"
                    + " source_bytes=\(value.receipt.sourceBytes) tensors=\(value.receipt.sourceTensors)"
                    + " load_ns=\(value.receipt.loadNanoseconds) sealed=\(codec == nil ? 0 : 1) buffer_cache=\(bufferCacheBytes)")
                try configuration.allocatorPolicy.prepareReady(
                    synchronize: { Stream.gpu.synchronize(); Stream.cpu.synchronize() },
                    snapshot: {
                        let s = Memory.snapshot()
                        return .init(activeBytes: s.activeMemory, cachedBytes: s.cacheMemory, peakBytes: s.peakMemory)
                    }, clearCache: { Memory.clearCache() }, check: checked)
                if configuration.allocatorPolicy == .disableFreedBufferCache {
                    // Ready: a bounded cache inside the gate's allocator headroom (see freedBufferCacheBytes).
                    Memory.cacheLimit = bufferCacheBytes
                    try checked()
                }
                let maximum = try Self.allowance(profile: source!, admission: admission,
                    maximumTokens: admission.profile.maximumContextTokens, chunkSize: admission.profile.maximumChunkTokens)
                try maximum.allowance.requireLive(additionalNativeBytes: maximum.extraNativeBytes)
                try checked()
                return try QwenLongPrefillCheckedBytes.sum([maximum.allowance.reservedBytes, maximum.extraNativeBytes])
            }
            guard let loaded = loadedModel, let receipt = shardReceipt, let profile = source else {
                throw ProbeError("Tensor-parallel load returned no shard")
            }
            try control.loaded()
            let budget = prefixEnabled ? max(1, QwenTensorParallelPrefixCache.defaultBudget(activeLoaded: Memory.activeMemory)) : 0
            return QwenTensorParallelResidentRuntime(admission: admission, control: control, collective: collective,
                group: group, codec: codec, model: loaded, profile: profile, shares: shares,
                loadAgreement: loadAgreement, capacity: capacity, receipt: receipt, linkProbe: probe,
                prefix: QwenTensorParallelPrefixCache(budgetBytes: budget))
        } catch {
            let primary = error; control.fail(); loadedModel = nil
            do {
                try MLX.withError { nativeError in
                    Stream.gpu.synchronize(); Stream.cpu.synchronize(); Memory.clearCache(); try nativeError.check()
                }
                guard retired == nil else { throw ProbeError("Tensor-parallel failed-load model remains retained") }
            } catch {
                throw ProbeError("Tensor-parallel load failed (\(primary)); local cleanup failed (\(error))")
            }
            throw primary
        }
    }

    private init(admission: QwenResidentAdmission, control: QwenResidentControl, collective: Collective,
                 group: QwenTensorParallelGroup, codec: QwenTensorParallelSealCodec?, model: QwenTensorParallelModel,
                 profile: QwenRegisteredDenseModelProfile, shares: [Int], loadAgreement: String, capacity: Int,
                 receipt: QwenTensorParallelShardReceipt, linkProbe: ClusterWorkerLinkProbe?,
                 prefix: QwenTensorParallelPrefixCache) {
        self.admission = admission; self.control = control; self.collective = collective; self.group = group
        self.codec = codec; self.model = model; self.profile = profile; self.shares = shares
        self.loadAgreement = loadAgreement; self.linkProbe = linkProbe; self.prefix = prefix
        self.receipt = receipt.storageCommitmentSHA256
        baseReady = .init(identity: admission.configuration.identity, rank: collective.rank,
            profile: admission.wireProfile, executionPlanSHA256: admission.plan.fingerprint,
            requestCapacityBytes: capacity, dataPlane: collective.workerDataPlane, linkProbe: linkProbe)
    }

    /// One request's charge on a rank: the pipeline's conservative named state
    /// of the whole model (every rank is charged as if it held every head, as
    /// the pipeline charges either rank), both stages' fused projections, and
    /// beside them the sealed reductions' frames of one prefill chunk and the
    /// gathered logits of one step.
    static func allowance(profile: QwenRegisteredDenseModelProfile, admission: QwenResidentAdmission,
                          maximumTokens: Int, chunkSize: Int) throws -> (allowance: QwenResidentRequestAllowance, extraNativeBytes: Int) {
        let bound = QwenResidentResourceEnvironment.allocationBound
        let first = try QwenResidentRequestAllowance.derive(profile: profile, plan: admission.plan, rank: 0,
            maximumTokens: maximumTokens, chunkSize: chunkSize, bound: bound)
        let second = try QwenResidentRequestAllowance.derive(profile: profile, plan: admission.plan, rank: 1,
            maximumTokens: maximumTokens, chunkSize: chunkSize, bound: bound)
        let reserved = try QwenLongPrefillCheckedBytes.sum([first.reservedBytes, second.fusionBytes])
        let frames = try QwenLongPrefillCheckedBytes.product([6, chunkSize, admission.profile.hiddenSize, 4])
        let logits = try QwenLongPrefillCheckedBytes.product([3, admission.profile.vocabularySize, 4])
        return (.init(stateBytes: first.stateBytes, fusionBytes: first.fusionBytes + second.fusionBytes,
                      reservedBytes: reserved, transientBytes: first.transientBytes, contextTokens: maximumTokens),
                try QwenLongPrefillCheckedBytes.sum([frames, logits]))
    }

    public var readiness: ClusterWorkerReady? {
        guard control.available, (try? control.check()) != nil else { return nil }
        return baseReady
    }

    public func keepWarmPulse() throws -> UInt64 {
        guard operation.try() else { throw ProbeError("Resident native operation is already active") }
        defer { operation.unlock() }
        guard control.available else { throw ProbeError("Keep-warm needs an idle resident owner") }
        return keepWarm.pulse()
    }

    public func dataPlanePing() throws -> UInt64 {
        guard operation.try() else { throw ProbeError("Resident native operation is already active") }
        defer { operation.unlock() }
        guard control.available else { throw ProbeError("Keep-warm needs an idle resident owner") }
        return try ClusterKeepWarm.dataPlanePing(collective: collective, check: { try control.check() })
    }

    public func reserve(requestID: UUID, request value: ClusterWorkerReservation) throws -> Int {
        guard operation.try() else { throw ProbeError("Resident native operation is already active") }
        defer { operation.unlock() }
        guard value.route == nil else { throw ProbeError("Under tensor parallel every request uses both ranks") }
        let request = try admission.request(value, id: requestID, now: DispatchTime.now().uptimeNanoseconds)
        try control.check(); try control.reserve(requestID)
        return try control.reserving(requestID, rank: collective.rank, deadline: value.deadlineUptimeNanoseconds) {
            guard model != nil else { throw ProbeError("Resident model already released") }
            let charge = try Self.allowance(profile: profile, admission: admission, maximumTokens: request.maximumTokens,
                chunkSize: min(request.chunkSize, request.promptCount))
            let total = try QwenLongPrefillCheckedBytes.sum([charge.allowance.reservedBytes, charge.extraNativeBytes])
            guard total <= value.capacityLimitBytes, total <= baseReady.requestCapacityBytes else {
                throw ProbeError("Tensor-parallel reservation exceeds its owner or readiness capacity ceiling")
            }
            // Kept prefixes give way before a reservation is refused for memory.
            try prefix.yieldingMemory { try charge.allowance.requireLive(additionalNativeBytes: charge.extraNativeBytes) }
            try control.check(deadline: value.deadlineUptimeNanoseconds)
            reservation = .init(request: request, allowance: charge.allowance, extraNativeBytes: charge.extraNativeBytes,
                deadline: value.deadlineUptimeNanoseconds)
            return total
        }
    }

    public func releaseReservation(requestID: UUID) throws {
        guard operation.try() else { throw ProbeError("Resident native operation is already active") }
        defer { operation.unlock() }
        guard let reserved = reservation, reserved.request.requestID == requestID, control.withdraw(requestID) else {
            throw ProbeError("Resident release has no matching unstarted reservation")
        }
        reservation = nil
    }

    /// Only rank 0 invokes the callback, once both ranks hold the token.
    /// False requests an agreed clean stop; a thrown callback is a failure.
    public func start(requestID: UUID,
                      onCommittedToken: (Int, Int, Int) throws -> Bool) throws -> QwenResidentGenerationCompletion {
        guard operation.try() else { throw ProbeError("Resident native operation is already active") }
        defer { operation.unlock() }
        guard let reserved = reservation, reserved.request.requestID == requestID else {
            throw ProbeError("Resident start has no matching reservation")
        }
        do {
            let value = try QwenResidentRequestPublication.run(control: control, lifecycle: lifecycle,
                identity: .init(requestID: requestID, epoch: requestID, recordedRequestFingerprint: reserved.request.fingerprint),
                deadline: reserved.deadline, body: {
                    try autoreleasepool { try generate(reserved, onCommittedToken: onCommittedToken) }
                }, prepare: { $0 })
            collective.logDataPlaneStatus()
            reservation = nil
            return value
        } catch {
            // The peer may hold another prefix state now: keep nothing.
            prefix.sweep()
            control.fail(); throw error
        }
    }

    public func cancel(requestID: UUID) { control.cancel(requestID) }

    public func shutdown() throws {
        guard operation.try() else { throw ProbeError("Cannot release a running native request") }
        defer { operation.unlock() }
        try control.beginClose()
        collective.logDataPlaneStatus()
        do {
            try lifecycle.withModelRelease {
                try MLX.withError { error in
                    Stream.gpu.synchronize(); Stream.cpu.synchronize(); try error.check()
                    prefix.sweep()
                    weak var released: QwenTensorParallelModel?
                    released = model; reservation = nil; model = nil
                    guard released == nil else { throw ProbeError("Tensor-parallel model remains retained") }
                    Memory.clearCache(); try error.check()
                }
            }
            control.closed()
            processLeaseOwned = false; QwenResidentProcessLease.shared.release()
        } catch { control.fail(); throw error }
    }

    deinit { if processLeaseOwned { control.fail() } }

    // MARK: - One request

    private func generate(_ reserved: Reserved, onCommittedToken: (Int, Int, Int) throws -> Bool) throws -> QwenResidentGenerationCompletion {
        guard let model else { throw ProbeError("Resident model already released") }
        let request = reserved.request, rank = collective.rank
        // Both ranks run the same request: its fingerprint (prompt, output
        // count, chunk, stop tokens, sampling) and this load's agreement.
        guard try group.digestsEqual(Self.digest64(request.fingerprint + "|" + loadAgreement)) else {
            throw ProbeError("Tensor-parallel ranks were given different requests")
        }
        let sampler = request.sampler
        let prompt = request.promptTokenIDs, chunk = max(1, request.chunkSize)
        var lastCheck: UInt64 = 0
        /// Local: true when this rank must ask both to stop (cancel, deadline, memory).
        func localStop() -> Bool {
            if (try? control.check(deadline: reserved.deadline)) == nil { return true }
            let now = DispatchTime.now().uptimeNanoseconds
            if now - lastCheck >= 250_000_000 {
                lastCheck = now
                if (try? prefix.yieldingMemory({ try reserved.allowance.requireLive(additionalNativeBytes: reserved.extraNativeBytes) })) == nil {
                    return true
                }
            }
            return false
        }

        // Prompt prefix: the longest chunk boundary both ranks hold.
        var cache = model.newCache()
        var start = 0
        let scope = loadAgreement + "|" + receipt
        if prefix.enabled, prompt.count > chunk {
            let candidates = QwenTensorParallelPrefixCache.candidates(promptCount: prompt.count, chunk: chunk)
            let held = prefix.heldBoundaries(scope: scope, prompt: prompt, chunk: chunk)
            if let agreed = try QwenTensorParallelPrefixCache.agree(held: held, group: group, candidates: candidates),
               let restored = prefix.restore(scope: scope, prompt: prompt, length: agreed) {
                cache = restored; start = agreed
            }
        }
        // Prefill from `start` in chunks aligned to the boundaries; keep the
        // last whole boundary before the final token.
        var logits: MLXArray?
        var offset = start
        let keepAt = prefix.enabled ? ((prompt.count - 1) / chunk) * chunk : 0
        while offset < prompt.count {
            let end = min(prompt.count, (offset / chunk + 1) * chunk)
            let input = MLXArray(prompt[offset ..< end].map { Int32($0) }).reshaped(1, end - offset)
            let out = model.forwardForRuntime(input, cache: cache)
            if end < prompt.count {
                eval(cache.flatMap { $0.innerState() })
                if end == keepAt, keepAt > start { prefix.store(scope: scope, prompt: prompt, length: end, cache: cache) }
            } else {
                logits = out[0..., -1, 0...]
            }
            offset = end
        }
        guard let firstLogits = logits else { throw ProbeError("Tensor-parallel prefill produced no logits") }

        func choose(_ stepLogits: MLXArray, stop: Float) -> (MLXArray, MLXArray) {
            guard let sampler else { return model.selectWithFlags(stepLogits, stop: stop) }
            // Every rank evaluates the logits gather before the choice is broadcast:
            // rank 0's draw reads it, and a rank that left it unevaluated would meet
            // rank 0's gather with the broadcast's reduction (the first sampled run on
            // the pair hung so: both ranks ended at the 60 s progress guard, status 75).
            let full = model.gatheredLogits(stepLogits)
            eval(full)
            let drawn = rank == 0 ? sampler.sample(full) : nil
            return model.broadcastChoice(drawn, stop: stop)
        }
        // Greedy steps are built one ahead (the next step's graph is submitted
        // before this token is read). A sampled step is built after the token
        // before it is committed: the product's sampler draws at the output
        // index with the history (penalties) up to it.
        let pipelined = sampler == nil
        var (current, currentFlags) = choose(firstLogits, stop: 0)
        asyncEval(current, currentFlags)
        var tokens: [Int] = []
        var finish: ClusterWorkerFinishReason = .length
        var clientStopped = false
        // 0, or the number of tokens to keep: what this rank puts in its stop
        // slot of every step built from now on.
        var stopKeep: Float = 0
        var pending: (MLXArray, MLXArray)?
        steps: for step in 0 ..< request.outputCount {
            pending = nil
            if pipelined, step + 1 < request.outputCount {
                let next = choose(model.step(current, cache: cache), stop: stopKeep)
                asyncEval(next.0, next.1)
                pending = next
            }
            let token = Int(current.item(Int32.self))
            let flags = currentFlags.asArray(Float.self).filter { $0 > 0 }
            if let keep = flags.min() {
                // A rank asked both to stop when this step was built: both keep
                // the tokens it named and end here.
                tokens = Array(tokens.prefix(Int(keep)))
                finish = .clientStop; break
            }
            if stopKeep == 0 {
                sampler?.commit(token)
                tokens.append(token)
                let wanted = rank == 0 ? try onCommittedToken(tokens.count - 1, token, prompt.count + tokens.count - 1) : true
                // A stop token, then the output limit, end the request at this
                // token whatever the answer (the engine answers "not wanted"
                // for the token that ends it); only an earlier "not wanted" is
                // a client stop (`QwenTensorParallelStopRule`).
                switch QwenTensorParallelStopRule.outcome(isStopToken: request.stopTokenIDs.contains(token),
                                                          committed: tokens.count, outputCount: request.outputCount, wanted: wanted) {
                case .eos: finish = .eos; break steps
                case .length: finish = .length; break steps   // the last step: nothing further was built
                case .clientStop: clientStopped = true
                case .proceed: break
                }
                if clientStopped || localStop() { stopKeep = Float(tokens.count) }
            }
            if !pipelined, step + 1 < request.outputCount {
                let next = choose(model.step(current, cache: cache), stop: stopKeep)
                asyncEval(next.0, next.1)
                pending = next
            }
            guard let (nextToken, nextFlags) = pending else { break }
            current = nextToken; currentFlags = nextFlags
            pending = nil
        }
        // A step both ranks built and submitted is evaluated by both, so its
        // reductions meet; nothing of it is emitted.
        if let pending { eval(pending.0, pending.1) }
        if stopKeep > 0 || clientStopped { finish = .clientStop }
        // Both ranks end on rank 0's outcome (one small sealed agreement, made
        // by both before either may throw below): a client stop rank 0 made
        // when no later step could carry its flag leaves rank 1 at the limit.
        let localFinish: QwenTensorParallelStopRule.Finish = finish == .eos ? .eos : finish == .length ? .length : .clientStop
        let agreed = try group.exchangeIntegers(rank == 0 ? [Int32(tokens.count), localFinish.code] : [0, 0])
        guard agreed.count == 2, let rank0Finish = QwenTensorParallelStopRule.Finish(code: agreed[1]) else {
            throw ProbeError("Tensor-parallel ranks did not agree how the request ended")
        }
        let ended = QwenTensorParallelStopRule.reconcile(rank: rank, localFinish: localFinish, localCount: tokens.count,
            localStopped: stopKeep > 0 && !clientStopped, rank0Finish: rank0Finish, rank0Count: Int(agreed[0]))
        tokens = Array(tokens.prefix(ended.count))
        switch ended.finish {
        case .eos: finish = .eos
        case .length: finish = .length
        case .clientStop: finish = .clientStop
        }
        try control.check(deadline: reserved.deadline)
        if finish == .clientStop && !clientStopped && rank == 0 {
            // The other rank asked to stop (cancelled or out of memory there).
            throw ProbeError("The peer rank stopped the tensor-parallel request")
        }
        let reused = start
        log("darkbloom-tensor-parallel-request-v1 rank=\(rank) request=\(request.requestID.uuidString.lowercased())"
            + " prompt=\(prompt.count) reused=\(reused) output=\(tokens.count) finish=\(finish.rawValue)"
            + " sampled=\(sampler == nil ? 0 : 1) frames=\(codec?.sealedFrames ?? 0) key_generation=\(codec?.keyGeneration ?? 0)")
        return QwenResidentGenerationCompletion(requestID: request.requestID, finishReason: finish,
            selectedTokenIDs: tokens, completedFrames: tokens.count, committedTokens: prompt.count + tokens.count,
            tokenChainSHA256: sha256(try canonicalJSONData(tokens.map { String($0) })), bothRequestStatesRetired: true,
            reusedPromptTokens: reused, storedPromptFrontiers: keepAt > 0 ? [keepAt] : [])
    }

    /// 64 bits of SHA-256 of `text`.
    static func digest64(_ text: String) -> UInt64 {
        let hex = sha256(Data(text.utf8))
        return UInt64(hex.prefix(16), radix: 16) ?? 0
    }
}
