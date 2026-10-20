import DarkbloomClusterProtocol
import DarkbloomClusterSecurity
import Foundation
import MLX
import MLXLLM

/// The worker's resident owner for `tensor_parallel_v1` on the registered GLM
/// row: both ranks hold every layer, each with half of every head- and
/// channel-parallel weight (`GLM5NextTensorShard`), run every prefill chunk and
/// decode step together, and sum each layer's attention and feed-forward
/// partials (float32, `ClusterTensorParallelTerms.current`) with the sealed
/// all-sum inside the lazy graph, under the session's keyed data plane.
///
/// The same executor contract as `QwenTensorParallelResidentRuntime`: one
/// request at a time, cancel from the control thread, an enclosing process
/// deadline required. Each decode step carries one small sealed reduction in
/// which both ranks put their token and stop flag: a greedy token both ranks
/// chose differently ends the request (it would mean diverged state), a
/// sampled token is rank 0's draw, and a stop on either rank ends both after
/// the same step.
///
/// Not in this mode yet (the pipeline serves them): prompt-prefix reuse, image
/// input and speculative (MTP) decode. A request asking for images is refused.
public final class GLM5NextTensorParallelResidentRuntime {
    static let planName = "glm5_next_heads_and_expert_channels_v1"
    /// The freed-buffer cache a ready rank keeps under the
    /// `disableFreedBufferCache` policy (the product's): the load runs with
    /// MLX's cache at zero, so the gate's accounting is exact while weights
    /// load; serving with it at zero creates every intermediate through the
    /// driver. (Under `unchanged` MLX keeps its own cache, as Qwen TP does.) Measured, sealed TP2 on two M5 Ultra
    /// (3,931-token prompt, 2,048-token chunks): cache 0 prefill 1,062 tok/s,
    /// decode 25.7; 1 GiB 1,624 / 50.4; 4 GiB 1,766 / 50.8. Charged to the
    /// load's memory gate and the stage residency beside the request reserve.
    static let freedBufferCacheBytes = 4 << 30
    /// Each prefill chunk runs as this many micro-batches, so one computes
    /// while another's sealed sum crosses the link
    /// (`GLM5NextTextStage.tensorParallelMicroBatches`). Measured, sealed TP2
    /// on two M5 Ultra (3,931-token prompt, 2,048-token chunks, 4 GiB cache):
    /// 1: 1,767 tok/s; 2: 2,532; 4: 1,466 (each micro-batch's matmuls too
    /// small); decode and tokens unchanged.
    static let prefillMicroBatches = 2

    let configuration: QwenResidentLoadConfiguration
    let descriptor: GLM5NextResidentDescriptor
    let control: QwenResidentControl
    let collective: Collective
    let group: QwenTensorParallelGroup
    let codec: QwenTensorParallelSealCodec?
    let lifecycle = QwenLayerStageResidentLifecycle()
    let loadAgreement: String
    private let operation = NSLock()
    private let keepWarm = ClusterKeepWarm()
    private var stage: GLM5NextTextStage?
    private var residency: ClusterStageResidency?
    private let requestReserveBytes: Int
    private let baseReady: ClusterWorkerReady
    private var reservation: Reserved?
    private var processLeaseOwned = true
    public let linkProbe: ClusterWorkerLinkProbe?

    struct Reserved {
        let request: QwenLayerStageGenerationRequest
        let deadline: UInt64
    }

    // MARK: - Load

    public static func load(_ configuration: QwenResidentLoadConfiguration,
                            qualification: QwenResidentQualificationSwitches = .refused,
                            dataPlane credential: ClusterDataPlaneCredential) throws -> GLM5NextTensorParallelResidentRuntime {
        let environment = ProcessInfo.processInfo.environment
        try qualification.admit(environment: environment)
        let spec = try GLM5NextRegisteredSpecification.specification(runtimeModelID: configuration.identity.modelID)
        guard spec.supportedGenerationModes.contains(.tensorParallel) else {
            throw ProbeError("Generation mode tensor_parallel_v1 is not in the GLM row")
        }
        let directory = configuration.modelDirectory
        let config = try BoundedProbeInput.data(directory.appendingPathComponent("config.json"),
            maximumBytes: GLM5NextRegisteredSpecification.maximumConfigurationBytes)
        let manifest = try BoundedProbeInput.data(directory.appendingPathComponent("manifest.json"),
            maximumBytes: GLM5NextRegisteredSpecification.maximumManifestBytes)
        // The launch checks a pipeline rank's admission makes
        // (`GLM5NextResidentAdmission`), less the stage-only ones. The cut
        // names the installed partition: its plan hash is the one READY
        // reports; under tensor parallel only its profile, artifact identity,
        // storage and policy are used.
        let identity = configuration.identity
        guard identity.configurationSHA256 == spec.configurationSHA256,
              identity.artifactSHA256 == spec.artifactSHA256,
              configuration.runtimeProfile == nil || configuration.runtimeProfile == spec.profileID,
              (0...1).contains(configuration.rank), spec.supportedCuts.contains(configuration.stageCut),
              directory.isFileURL, configuration.prefillSchedule == .serial,
              configuration.admitsLoadDeadline(now: DispatchTime.now().uptimeNanoseconds),
              identity.peers.count == 2, identity.peers[0].id != identity.peers[1].id,
              identity.peers.allSatisfy({ !$0.id.isEmpty && $0.id.utf8.count <= 128
                  && $0.id.utf8.allSatisfy({ (33...126).contains($0) }) && qwenStageWireIsSHA256($0.buildSHA256) }) else {
            throw ProbeError("GLM tensor-parallel launch differs from the registered model, its partitions, peers or lifetime")
        }
        let descriptor = try spec.descriptor(configuration: config, manifest: manifest, cut: configuration.stageCut)
        // READY names the plan of the partition the leader installed (the
        // capability metadata's hash for this cut), as a pipeline rank does.
        let planSHA256 = try GLM5NextServingResources.contract(specification: spec,
            configuration: descriptor.configuration, artifactIdentity: descriptor.artifactIdentity,
            cut: descriptor.cut).source.planFingerprint
        let inventory = try descriptor.inspectInventory(directory: directory)
        guard GLM5NextArtifactMetadata.fingerprint(inventory) == spec.inventorySHA256 else {
            throw ProbeError("GLM shard headers are not the registered inventory")
        }
        // Every rank is charged the request state of both pipeline stages: the
        // whole model's latent caches (replicated under TP) and all its KDA
        // state (charged whole, although a rank holds half its heads), so the
        // charge is never below the need. Beside it, one sealed sum's buffers
        // at the largest chunk: the float32 partial, its sealed frame, both
        // ranks' frames, the opened peer partial and the sum (six partials).
        let profile = descriptor.profile
        var requestReserve = try QwenLongPrefillCheckedBytes.product([6, profile.maximumChunkTokens,
            descriptor.configuration.textConfig.hiddenSize, 4])
        for rank in 0 ..< 2 {
            let resources = try GLM5NextServingResources.envelope(descriptor: descriptor, inventory: inventory,
                rank: rank, buildSHA256: configuration.identity.peers[rank].buildSHA256)
            let quote = try resources.quote(descriptor: descriptor, maximumBufferBytes: GPU.deviceInfo().maxBufferSize,
                allocationBound: QwenResidentResourceEnvironment.allocationBound)
            requestReserve = try QwenLongPrefillCheckedBytes.sum([requestReserve, quote.request.reservedBytes])
        }
        let shardBytes = try Self.shardBytes(inventory)
        let control = QwenResidentControl(deadline: configuration.deadlineUptimeNanoseconds, lease: configuration.lease)
        try QwenResidentProcessLease.shared.acquire()
        var loaded: GLM5NextTextStage?
        weak var retired: GLM5NextTextStage?
        do {
            try control.check(); try QwenResidentResourceEnvironment.require()
            let read: (URL, Int) throws -> Data = { try BoundedProbeInput.data($0, maximumBytes: $1) }
            let jaccl = try QwenResidentJACCLConfiguration.admit(environment: environment, read: read)
            guard jaccl.rank == configuration.rank else { throw ProbeError("GLM launch rank differs from JACCL") }
            let collective = try Collective(transport: .jaccl)
            try jaccl.requireUnchanged(environment: ProcessInfo.processInfo.environment, read: read)
            try jaccl.requireInitialized(rank: collective.rank, worldSize: collective.size, transport: collective.transport)
            let identity = configuration.identity
            let loadAgreement = sha256(try canonicalJSONData(["glm5-next-tensor-parallel-load-v1", planName,
                descriptor.fingerprint, identity.membershipEpoch.uuidString.lowercased(), jaccl.fingerprint,
                collective.transport.rawValue, configuration.allocatorPolicy.rawValue]
                + ClusterGenerationMode.tensorParallel.loadAgreementFields + ClusterDataPlaneAgreement.loadAgreementFields
                + identity.peers.flatMap { [$0.id, $0.buildSHA256] }))
            try ClusterDataPlaneAgreement.establish(collective: collective, credential: credential,
                loadAgreement: loadAgreement, tamper: nil, tensorParallelSeal: true, check: { try control.check() })
            guard collective.workerDataPlane?.peerVerified == true else {
                throw ProbeError("GLM tensor parallel requires an authenticated peer")
            }
            let group = try QwenTensorParallelGroup(collective: collective)
            let codec = try QwenTensorParallelSealCodec.product(collective: collective, scope: Data(loadAgreement.utf8))
            try codec.install()
            group.sealed = codec
            var probe: ClusterWorkerLinkProbe?
            var stageResidency: ClusterStageResidency?
            let started = DispatchTime.now().uptimeNanoseconds
            try MLX.withError { nativeError in
                func checked() throws { try nativeError.check(); try control.check(); try nativeError.check() }
                try configuration.allocatorPolicy.configure(setCacheLimit: { Memory.cacheLimit = $0 }, check: checked)
                let bufferCacheBytes = configuration.allocatorPolicy == .disableFreedBufferCache
                    ? Self.freedBufferCacheBytes : 0
                _ = try requireQwenLongPrefillReadinessDigest(collective: collective,
                    material: { .residentLoadIntent(agreementFingerprint: loadAgreement) },
                    disagreementMessage: "GLM tensor-parallel load membership/source/plan differ",
                    scope: .session(.loadAgreement, "glm-tensor-parallel-load-intent"), check: checked)
                // The link as this mode uses it, before any weight is read: the
                // planner's measured reduction costs for this pair.
                let measured = try QwenTensorParallelLinkProbe.measure(collective: collective, group: group,
                    hiddenSize: descriptor.configuration.textConfig.hiddenSize,
                    chunkTokens: descriptor.profile.maximumChunkTokens, check: checked)
                probe = measured
                log(QwenTensorParallelLinkProbe.line(measured, rank: collective.rank))
                // The live gate admits this rank's shard and the whole request charge before any read.
                try requireLiveMemory(bytes: try QwenLongPrefillCheckedBytes.sum([shardBytes, requestReserve, bufferCacheBytes]))
                let roots = GLM5NextArtifactLoadRoots()
                let loader = try GLM5NextArtifactLoader(directory: directory, expectedIdentity: descriptor.artifactIdentity,
                    storage: descriptor.storage, constructionRoots: roots, executionPolicy: descriptor.executionPolicy)
                guard GLM5NextArtifactMetadata.fingerprint(loader.inventory) == spec.inventorySHA256 else {
                    throw ProbeError("GLM verified owner differs from the registered inventory")
                }
                let text = loader.configuration.textConfig
                let plan = try GLM5NextTextStagePlan(configuration: text, layers: 0 ..< text.hiddenLayers,
                    shard: try GLM5NextTensorShard(rank: collective.rank, size: collective.size))
                let value = try autoreleasepool { try loader.loadTextStage(plan: plan) }
                value.tensorParallelMicroBatches = Self.prefillMicroBatches
                value.freeze()
                try roots.evaluate(value.parameters().flattened().map(\.1))
                Stream.gpu.synchronize(); try checked()
                roots.releaseAfterConfirmedFence()
                try loader.verifyUnchanged()
                try value.installTensorParallelReduction { partial in
                    // One rounding, as the terms fix: float32 partials summed sealed.
                    group.allSum(partial.asType(.float32)).asType(partial.dtype)
                }
                loaded = value; retired = value
                Memory.clearCache()
                stageResidency = try ClusterStageResidency(bytes: try QwenLongPrefillCheckedBytes.sum([
                    Memory.activeMemory, requestReserve, bufferCacheBytes]))
                if bufferCacheBytes > 0 { Memory.cacheLimit = bufferCacheBytes; try checked() }
                let loadedIdentity = sha256(try canonicalJSONData([loadAgreement, descriptor.artifactAggregateSHA256,
                    String(shardBytes)]))
                _ = try requireQwenLongPrefillReadinessDigest(collective: collective,
                    material: { .residentLoaded(agreementFingerprint: loadedIdentity) },
                    disagreementMessage: "GLM tensor-parallel peers did not load matching shards",
                    scope: .session(.loadedReady, "glm-tensor-parallel-loaded"), check: checked)
                log("darkbloom-tensor-parallel-load-v1 rank=\(collective.rank) plan=\(planName) shares=1-1"
                    + " shard_bytes=\(shardBytes) source_bytes=\(inventory.entries.values.reduce(0) { $0 + $1.bytes })"
                    + " tensors=\(inventory.entries.count) load_ns=\(DispatchTime.now().uptimeNanoseconds - started)"
                    + " cut=\(descriptor.cut) launch_cut=\(configuration.stageCut) micro_batches=\(Self.prefillMicroBatches) sealed=1 buffer_cache=\(bufferCacheBytes) wired_limit=\(stageResidency?.receipt.appliedBytes ?? 0)")
            }
            guard let stage = loaded else { throw ProbeError("GLM tensor-parallel load returned no stage") }
            try control.loaded()
            return GLM5NextTensorParallelResidentRuntime(configuration: configuration, descriptor: descriptor,
                control: control, collective: collective, group: group, codec: codec, stage: stage,
                residency: stageResidency, requestReserveBytes: requestReserve, loadAgreement: loadAgreement, linkProbe: probe,
                planSHA256: planSHA256)
        } catch {
            let primary = error; control.fail(); loaded = nil
            do {
                try MLX.withError { nativeError in
                    Stream.gpu.synchronize(); Stream.cpu.synchronize(); Memory.clearCache(); try nativeError.check()
                }
                guard retired == nil else { throw ProbeError("GLM tensor-parallel failed-load stage remains retained") }
            } catch {
                throw ProbeError("GLM tensor-parallel load failed (\(primary)); local cleanup failed (\(error))")
            }
            throw primary
        }
    }

    /// Bytes one rank holds of the text model: its half of every split tensor,
    /// all of every replicated one.
    static func shardBytes(_ inventory: GLM5NextWeightInventory) throws -> Int {
        try inventory.entries(in: .text).reduce(0) { total, entry in
            let bytes = GLM5NextTensorShard.splitAxis(entry.tensor.name) == nil ? entry.bytes : entry.bytes / 2
            return try QwenLongPrefillCheckedBytes.sum([total, bytes])
        }
    }

    /// The host memory gate's decision for `bytes` more, as the resident families take it.
    static func requireLiveMemory(bytes: Int) throws {
        try QwenResidentResourceEnvironment.require()
        let watch = QwenDenseStageLoadWatch("GLM tensor-parallel")
        let os = try QwenDenseStageLoadResources.observeOS()
        let free = max(QwenDenseStageLoadPolicy.minimumAdmissibleBytes,
            try QwenLongPrefillCheckedBytes.sum([bytes, QwenDenseStageLoadPolicy.loadingHeadroomBytes]))
        guard try watch.admits(os, bytes: free) else {
            throw ProbeError("GLM tensor parallel needs \(bytes) bytes the memory gate does not admit now")
        }
    }

    private init(configuration: QwenResidentLoadConfiguration, descriptor: GLM5NextResidentDescriptor,
                 control: QwenResidentControl, collective: Collective, group: QwenTensorParallelGroup,
                 codec: QwenTensorParallelSealCodec?, stage: GLM5NextTextStage, residency: ClusterStageResidency?,
                 requestReserveBytes: Int, loadAgreement: String, linkProbe: ClusterWorkerLinkProbe?,
                 planSHA256: String) {
        self.configuration = configuration; self.descriptor = descriptor; self.control = control
        self.collective = collective; self.group = group; self.codec = codec; self.stage = stage
        self.residency = residency; self.requestReserveBytes = requestReserveBytes
        self.loadAgreement = loadAgreement; self.linkProbe = linkProbe
        baseReady = .init(identity: configuration.identity, rank: collective.rank, profile: descriptor.wireProfile,
            executionPlanSHA256: planSHA256, requestCapacityBytes: requestReserveBytes,
            dataPlane: collective.workerDataPlane, linkProbe: linkProbe)
    }

    // MARK: - Owner interface

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
        guard control.available else { throw ProbeError("A data-plane ping needs an idle resident owner") }
        return try ClusterKeepWarm.dataPlanePing(collective: collective, check: { try control.check() })
    }

    public func reserve(requestID: UUID, request value: ClusterWorkerReservation) throws -> Int {
        guard operation.try() else { throw ProbeError("Resident native operation is already active") }
        defer { operation.unlock() }
        let now = DispatchTime.now().uptimeNanoseconds
        guard value.route == nil, value.stillImages == nil, value.mimoImages == nil,
              value.profileID == descriptor.profile.identifier,
              value.stopTokenIDs == Array(Set(value.stopTokenIDs)).sorted(), value.capacityLimitBytes > 0,
              configuration.admitsRequestDeadline(value.deadlineUptimeNanoseconds, now: now) else {
            throw ProbeError("GLM tensor-parallel reservation differs from its profile, route, media or deadline")
        }
        let request = try QwenLayerStageGenerationRequest(profile: descriptor.profile, requestID: requestID,
            promptTokenIDs: value.promptTokenIDs, chunkSize: value.chunkSize, outputCount: value.outputCount,
            stopTokenIDs: Set(value.stopTokenIDs), sampling: value.sampling, stillImages: nil)
        try control.check(); try control.reserve(requestID)
        return try control.reserving(requestID, rank: collective.rank, deadline: value.deadlineUptimeNanoseconds) {
            guard stage != nil else { throw ProbeError("Resident model already released") }
            guard requestReserveBytes <= value.capacityLimitBytes else {
                throw ProbeError("GLM tensor-parallel reservation exceeds its owner or readiness capacity")
            }
            try Self.requireLiveMemory(bytes: requestReserveBytes)
            try control.check(deadline: value.deadlineUptimeNanoseconds)
            reservation = .init(request: request, deadline: value.deadlineUptimeNanoseconds)
            return requestReserveBytes
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
                    weak var released: GLM5NextTextStage?
                    released = stage; reservation = nil; stage = nil
                    guard released == nil else { throw ProbeError("GLM tensor-parallel stage remains retained") }
                    try residency?.end(); residency = nil
                    Memory.clearCache(); try error.check()
                }
            }
            control.closed()
            processLeaseOwned = false; QwenResidentProcessLease.shared.release()
        } catch { control.fail(); throw error }
    }

    deinit { if processLeaseOwned { control.fail() } }

    // MARK: - One request

    private func generate(_ reserved: Reserved, onCommittedToken: (Int, Int, Int) throws -> Bool) throws
        -> QwenResidentGenerationCompletion {
        guard let stage else { throw ProbeError("Resident model already released") }
        let request = reserved.request, rank = collective.rank
        guard try group.digestsEqual(QwenTensorParallelResidentRuntime.digest64(request.fingerprint + "|" + loadAgreement)) else {
            throw ProbeError("GLM tensor-parallel ranks were given different requests")
        }
        let sampler = request.sampler
        let prompt = request.promptTokenIDs, chunk = max(1, request.chunkSize)
        var lastCheck: UInt64 = 0
        func localStop() -> Bool {
            if (try? control.check(deadline: reserved.deadline)) == nil { return true }
            let now = DispatchTime.now().uptimeNanoseconds
            if now - lastCheck >= 250_000_000 {
                lastCheck = now
                if (try? Self.requireLiveMemory(bytes: 0)) == nil { return true }
            }
            return false
        }
        let cache = stage.newCache()
        var logits: MLXArray?
        var offset = 0
        while offset < prompt.count {
            let end = min(prompt.count, offset + chunk)
            let last = end == prompt.count
            let tokens = MLXArray(prompt[offset ..< end].map(Int32.init), [1, end - offset])
            let candidate = try stage.prepareForward(tokens: tokens, cache: cache, readout: last ? .lastToken : .none)
            try candidate.commit { roots in eval(roots) }
            if last, case .final(let output) = candidate.output { logits = output.logits[0..., -1, 0...] }
            offset = end
        }
        guard let firstLogits = logits else { throw ProbeError("GLM tensor-parallel prefill produced no logits") }

        // One small sealed reduction per step: [token rank 0, token rank 1,
        // stop rank 0, stop rank 1]. Greedy: both ranks put their own choice
        // and must agree. Sampled: rank 0 draws, rank 1 puts 0 and adopts it.
        func choose(_ row: MLXArray, stop: Float) -> MLXArray {
            let local: MLXArray
            if let sampler {
                let drawn = rank == 0 ? sampler.sample(row) : MLXArray(Int32(0))
                local = drawn.asType(.float32).reshaped(1)
            } else {
                local = argMax(row.asType(.float32), axis: -1).asType(.float32).reshaped(1)
            }
            let zero = MLXArray.zeros([1], dtype: .float32)
            let tokens = rank == 0 ? [local, zero] : [zero, local]
            let stops = rank == 0 ? [MLXArray([stop]), zero] : [zero, MLXArray([stop])]
            return group.allSum(concatenated(tokens + stops, axis: 0))
        }
        func token(_ agreed: [Float]) throws -> Int {
            guard agreed.count == 4 else { throw ProbeError("GLM tensor-parallel selection has a wrong shape") }
            if sampler == nil, agreed[0] != agreed[1] {
                throw ProbeError("GLM tensor-parallel ranks chose different greedy tokens")
            }
            return Int(agreed[0])
        }
        // Greedy steps are built one ahead: step k+1 is submitted before step
        // k's choice is read. A sampled step is built after its token is known
        // (the sampler draws at the output index with the history up to it).
        let pipelined = sampler == nil
        var current = choose(firstLogits, stop: 0)
        asyncEval(current)
        var tokens: [Int] = []
        var finish: ClusterWorkerFinishReason = .length
        var clientStopped = false
        var stopKeep: Float = 0
        var pending: MLXArray?
        func step(from selection: MLXArray, stop: Float) throws -> MLXArray {
            let next = selection[0 ..< 1].asType(.int32).reshaped(1, 1)
            let candidate = try stage.prepareForward(tokens: next, cache: cache, readout: .lastToken)
            try candidate.commit { roots in asyncEval(roots) }
            guard case .final(let output) = candidate.output else { throw ProbeError("GLM tensor-parallel decode produced no logits") }
            let chosen = choose(output.logits[0..., -1, 0...], stop: stop)
            asyncEval(chosen)
            return chosen
        }
        steps: for index in 0 ..< request.outputCount {
            pending = nil
            if pipelined, index + 1 < request.outputCount { pending = try step(from: current, stop: stopKeep) }
            let agreed = current.asArray(Float.self)
            let value = try token(agreed)
            let flags = [agreed[2], agreed[3]].filter { $0 > 0 }
            if let keep = flags.min() {
                tokens = Array(tokens.prefix(Int(keep)))
                finish = .clientStop; break
            }
            if stopKeep == 0 {
                sampler?.commit(value)
                tokens.append(value)
                let wanted = rank == 0 ? try onCommittedToken(tokens.count - 1, value, prompt.count + tokens.count - 1) : true
                switch QwenTensorParallelStopRule.outcome(isStopToken: request.stopTokenIDs.contains(value),
                                                          committed: tokens.count, outputCount: request.outputCount, wanted: wanted) {
                case .eos: finish = .eos; break steps
                case .length: finish = .length; break steps
                case .clientStop: clientStopped = true
                case .proceed: break
                }
                if clientStopped || localStop() { stopKeep = Float(tokens.count) }
            }
            if !pipelined, index + 1 < request.outputCount { pending = try step(from: current, stop: stopKeep) }
            guard let next = pending else { break }
            current = next; pending = nil
        }
        // A step both ranks submitted is evaluated by both, so its reductions meet.
        if let pending { eval(pending) }
        if stopKeep > 0 || clientStopped { finish = .clientStop }
        let localFinish: QwenTensorParallelStopRule.Finish = finish == .eos ? .eos : finish == .length ? .length : .clientStop
        let agreedEnd = try group.exchangeIntegers(rank == 0 ? [Int32(tokens.count), localFinish.code] : [0, 0])
        guard agreedEnd.count == 2, let rank0Finish = QwenTensorParallelStopRule.Finish(code: agreedEnd[1]) else {
            throw ProbeError("GLM tensor-parallel ranks did not agree how the request ended")
        }
        let ended = QwenTensorParallelStopRule.reconcile(rank: rank, localFinish: localFinish, localCount: tokens.count,
            localStopped: stopKeep > 0 && !clientStopped, rank0Finish: rank0Finish, rank0Count: Int(agreedEnd[0]))
        tokens = Array(tokens.prefix(ended.count))
        switch ended.finish {
        case .eos: finish = .eos
        case .length: finish = .length
        case .clientStop: finish = .clientStop
        }
        try control.check(deadline: reserved.deadline)
        if finish == .clientStop && !clientStopped && rank == 0 {
            throw ProbeError("The peer rank stopped the GLM tensor-parallel request")
        }
        log("darkbloom-tensor-parallel-request-v1 rank=\(rank) request=\(request.requestID.uuidString.lowercased())"
            + " prompt=\(prompt.count) reused=0 output=\(tokens.count) finish=\(finish.rawValue)"
            + " sampled=\(sampler == nil ? 0 : 1) frames=\(codec?.sealedFrames ?? 0) key_generation=\(codec?.keyGeneration ?? 0)")
        return QwenResidentGenerationCompletion(requestID: request.requestID, finishReason: finish,
            selectedTokenIDs: tokens, completedFrames: tokens.count, committedTokens: prompt.count + tokens.count,
            tokenChainSHA256: sha256(try canonicalJSONData(tokens.map { String($0) })), bothRequestStatesRetired: true,
            reusedPromptTokens: 0, storedPromptFrontiers: [])
    }
}
