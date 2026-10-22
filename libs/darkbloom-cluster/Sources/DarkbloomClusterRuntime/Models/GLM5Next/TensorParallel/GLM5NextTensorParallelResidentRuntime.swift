import Cmlx
import DarkbloomClusterProtocol
import DarkbloomClusterSecurity
import Foundation
import MLX
import MLXLLM
import MLXLMCommon

/// The worker's resident owner for `tensor_parallel_v1` on the registered GLM
/// row: both ranks hold every layer, each with half of every head- and
/// channel-parallel weight (`GLM5NextTensorShard`), run every prefill chunk and
/// decode step together, and sum each layer's attention and feed-forward
/// partials (float32, `ClusterTensorParallelTerms.current`) with the sealed
/// all-sum inside the lazy graph, under the session's keyed data plane.
///
/// The same executor contract as `QwenTensorParallelResidentRuntime`: one
/// request at a time, cancel from the control thread, an enclosing process
/// deadline required; or, loaded with batch lanes (`lanes`, from
/// `DARKBLOOM_CLUSTER_BATCH_LANES`), several requests at once in the lane loop
/// (`GLM5NextTensorParallelLanes.swift`), each with its own arithmetic. Each decode step carries one small sealed reduction in
/// which both ranks put their token and stop flag: a greedy token both ranks
/// chose differently ends the request (it would mean diverged state), a
/// sampled token is rank 0's draw, and a stop on either rank ends both after
/// the same step.
///
/// Greedy requests decode speculatively with the model's own NextN (MTP)
/// layer, which every rank holds whole (`mtpDepth`,
/// `GLM5NextTensorParallelSpeculation`): one stage forward verifies up to
/// `mtpDepth` proposals, and its round's reduction carries every window
/// position's token, the proposals and the stop flags. Sampled requests
/// decode one token per step.
///
/// Not in this mode yet (the pipeline serves it): image input. A request
/// asking for images is refused.
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
    /// Given back once the rank is idle (`releaseIdleMemory`), and before a
    /// reservation or a running request is refused (`yieldingMemory`).
    static let freedBufferCacheBytes = 4 << 30
    /// Each prefill chunk runs as this many micro-batches, so one computes
    /// while another's sealed sum crosses the link
    /// (`GLM5NextTextStage.tensorParallelMicroBatches`). Measured, sealed TP2
    /// on two M5 Ultra (3,931-token prompt, 2,048-token chunks, 4 GiB cache):
    /// 1: 1,767 tok/s; 2: 2,532; 4: 1,466 (each micro-batch's matmuls too
    /// small); decode and tokens unchanged.
    static let prefillMicroBatches = 2
    /// How partials cross, bound into the load agreement beside the terms.
    /// `ClusterTensorParallelTerms` keeps partials in float32 until the sum;
    /// GLM's row-parallel projections already emit bfloat16, so widening them
    /// before the link sent zero bits: the sealed sum of the bfloat16 partials
    /// (each widened exactly, added in float32, rounded once) is bit-identical
    /// to it, with half the bytes. Measured, sealed TP2 on two M5 Ultra
    /// (15,724-token prompt): prefill 2,861 -> 3,261 tok/s, decode 48.8 -> 51.1,
    /// tokens identical. Owner-approved 2026-10-20; flagged for platform review.
    static let partialsTransport = "glm5-next-partials-stored-bfloat16-sum-float32-rounded-once-v1"
    /// Prefill runs chunks of this many tokens (a multiple of the request's
    /// chunk): the M5 neural accelerators reach ~94 TFLOPS on 4,096-row NVFP4
    /// matmuls against ~62 at 2,048. Measured, sealed TP2 with 2 micro-batches:
    /// 3,931-token prompt 2,518 -> 2,841 tok/s, 15,724-token prompt 2,371 ->
    /// 2,771 (8,192: 2,579). Charged as a second request workspace beside the
    /// profile's 2,048-token one, and the sealed sums' buffers at this size.
    static let prefillChunkTokens = 4096
    /// Bulk prefill runs chunks of this many tokens where the prompt allows,
    /// still as two micro-batches (4,096 rows each); the last stretch before
    /// the prefix boundary keeps `prefillChunkTokens`, so prompt prefixes
    /// are still kept at every 4,096 tokens. Measured, sealed TP2 (bfloat16
    /// partials, 15,724-token prompt): 4,096-token chunks 3,311 tok/s,
    /// 8,192: 3,614. Charged as four request workspaces in all.
    static let bulkPrefillChunkTokens = 8192
    /// A request with no other lane decoding prefills consecutive chunks
    /// together in one graph (frame), up to this many tokens
    /// (`GLM5NextTensorParallelPrefillPlan`; 0: each chunk alone). Every
    /// chunk keeps its micro-batches, so tokens are unchanged; a graph's edges
    /// leave its last sums waiting for the link and its first micro-batches
    /// with nothing to overlap, and a longer graph overlaps each sum with more
    /// micro-batches (bulk chunks as 4 x 4,096 instead of 2 x 4,096 on the
    /// 15.7K prompt: 3,819 -> 4,086 tok/s). The prompt-prefix boundary may fall
    /// inside a graph (the stage keeps its cache there). No further charge:
    /// MLX keeps at most `MLX_MAX_ACTIVE_TASKS` command buffers in flight
    /// whatever the graph's length, so a longer graph holds only each
    /// micro-batch's residual streams and the graph's hidden rows longer
    /// (about 1 GiB more at 16,384 tokens), far inside the bulk chunk's
    /// workspaces.
    static let mergedPrefillTokens = 16384
    /// Chunks whose micro-batches are all large enough to compute the same
    /// bits at any size (`GLM5NextTensorParallelPrefillPlan.rowCountInvariantRows`)
    /// run as micro-batches of at most this many rows instead (nil: two per
    /// chunk). Bigger micro-batches read each layer's expert weights once per
    /// more rows; tokens are unchanged.
    static let prefillMicroBatchTokens: Int? = nil
    /// NextN (MTP) proposals each greedy decode round verifies
    /// (`GLM5NextTensorParallelSpeculation`, at most
    /// `GLM5NextMTP.maximumProposalDepth`); 0 loads no NextN layer and every
    /// request decodes one token per step. Bound into the load agreement.
    /// The NextN layer is replicated whole on each rank: +4.2 GB of weights
    /// per rank, charged to the load gate beside the shard
    /// (`speculationRequestBytes` for its request state). Measured on the
    /// pair (sealed, 3,931-token prompt, 256 tokens): one token per step
    /// 62.6 tok/s; depth 1 68.7, depth 2 76.0 (2.24 tokens a round), depth 3
    /// 71.8 (its third proposal is rarely kept and widens every window).
    static let mtpDepth = 2

    let configuration: QwenResidentLoadConfiguration
    let descriptor: GLM5NextResidentDescriptor
    let control: QwenResidentControl
    let collective: Collective
    let group: QwenTensorParallelGroup
    let codec: QwenTensorParallelSealCodec?
    let lifecycle = QwenLayerStageResidentLifecycle()
    let loadAgreement: String
    let operation = NSLock()
    private let keepWarm = ClusterKeepWarm()
    var stage: GLM5NextTextStage?
    /// The NextN layer when `mtpDepth > 0`; it shares the stage's embedding and head.
    var mtp: GLM5NextMTP?
    private var residency: ClusterStageResidency?
    let requestReserveBytes: Int
    private let baseReady: ClusterWorkerReady
    private var reservation: Reserved?
    private var processLeaseOwned = true
    public let linkProbe: ClusterWorkerLinkProbe?
    /// This rank's prompt prefixes (`GLM5NextTensorParallelPrefixCache`).
    let prefix: GLM5NextTensorParallelPrefixCache
    /// Requests served at once (continuous batching); one serves one request
    /// at a time exactly as before. Bound into the load agreement.
    public let lanes: QwenBatchSettings
    /// Batch lanes: every reserved, started and running lane on this rank.
    let laneBook = ClusterBatchLaneBook<GLM5NextTensorParallelLaneReservation>()
    /// True while the lane loop runs on the executor (lane control is applied
    /// inside it, under its exclusive operation).
    var batchServing = false

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
        let lanes = try QwenBatchSettings.fromEnvironment(environment)
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
        let largestChunk = max(profile.maximumChunkTokens, Self.bulkPrefillChunkTokens)
        var requestReserve = try QwenLongPrefillCheckedBytes.sum([
            try QwenLongPrefillCheckedBytes.product([6, largestChunk, descriptor.configuration.textConfig.hiddenSize, 4]),
            try QwenLongPrefillCheckedBytes.product([largestChunk / max(1, profile.maximumChunkTokens) - 1,
                GLM5NextServingResources.workspaceNativeBytes])])
        for rank in 0 ..< 2 {
            let resources = try GLM5NextServingResources.envelope(descriptor: descriptor, inventory: inventory,
                rank: rank, buildSHA256: configuration.identity.peers[rank].buildSHA256)
            let quote = try resources.quote(descriptor: descriptor, maximumBufferBytes: GPU.deviceInfo().maxBufferSize,
                allocationBound: QwenResidentResourceEnvironment.allocationBound)
            requestReserve = try QwenLongPrefillCheckedBytes.sum([requestReserve, quote.request.reservedBytes])
        }
        let shardBytes = try Self.shardBytes(inventory)
        // Every rank holds the NextN layer whole: its loader never shards, so
        // its bytes are the stored ones (`GLM5NextTensorShard.splitAxis` has
        // no layer bound and would wrongly halve some of them).
        let text = descriptor.configuration.textConfig
        guard Self.mtpDepth == 0 || (text.numNextNPredictLayers == 1
                && Self.mtpDepth <= GLM5NextMTP.maximumProposalDepth
                && (Self.mtpDepth == 1 || text.indexShareForMTPIteration)) else {
            throw ProbeError("GLM tensor-parallel speculative depth \(Self.mtpDepth) is unsupported by this model")
        }
        let mtpBytes = Self.mtpDepth > 0 ? inventory.bytes(in: .mtp) : 0
        requestReserve = try QwenLongPrefillCheckedBytes.sum([requestReserve,
            try Self.speculationRequestBytes(configuration: text, profile: profile, depth: Self.mtpDepth,
                executionPolicy: descriptor.executionPolicy)])
        // The prefix cache votes in a reduction of its own: both ranks must
        // have it on, or both off (`DARKBLOOM_CLUSTER_PREFIX_CACHE=off`).
        let prefixEnabled = QwenStagePrefixCache.fromEnvironment(environment).enabled
        let control = QwenResidentControl(deadline: configuration.deadlineUptimeNanoseconds, lease: configuration.lease)
        try QwenResidentProcessLease.shared.acquire()
        var loaded: GLM5NextTextStage?
        var loadedMTP: GLM5NextMTP?
        weak var retired: GLM5NextTextStage?
        weak var retiredMTP: GLM5NextMTP?
        do {
            try control.check(); try QwenResidentResourceEnvironment.require()
            let read: (URL, Int) throws -> Data = { try BoundedProbeInput.data($0, maximumBytes: $1) }
            let jaccl = try QwenResidentJACCLConfiguration.admit(environment: environment, read: read)
            guard jaccl.rank == configuration.rank else { throw ProbeError("GLM launch rank differs from JACCL") }
            let collective = try Collective(transport: .jaccl)
            try jaccl.requireUnchanged(environment: ProcessInfo.processInfo.environment, read: read)
            try jaccl.requireInitialized(rank: collective.rank, worldSize: collective.size, transport: collective.transport)
            let identity = configuration.identity
            let loadAgreement = sha256(try canonicalJSONData(["glm5-next-tensor-parallel-load-v1", planName, partialsTransport,
                GLM5NextTensorParallelSpeculation.agreementName, String(mtpDepth),
                descriptor.fingerprint, identity.membershipEpoch.uuidString.lowercased(), jaccl.fingerprint,
                collective.transport.rawValue, configuration.allocatorPolicy.rawValue,
                "glm5-next-tensor-parallel-prefix-v1", prefixEnabled ? "on" : "off"]
                + Self.laneAgreementFields(lanes)
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
            var prefixBudget = 0
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
                try requireLiveMemory(bytes: try QwenLongPrefillCheckedBytes.sum([shardBytes, mtpBytes, requestReserve,
                    bufferCacheBytes]))
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
                // The NextN layer, whole, bound to the stage's replicated embedding and head.
                let head = Self.mtpDepth > 0 ? try autoreleasepool { try loader.loadMTP(stage: value) } : nil
                head?.freeze()
                loadedMTP = head; retiredMTP = head
                try roots.evaluate(value.parameters().flattened().map(\.1)
                    + (head?.parameters().flattened().map(\.1) ?? []))
                Stream.gpu.synchronize(); try checked()
                roots.releaseAfterConfirmedFence()
                try loader.verifyUnchanged()
                try value.installTensorParallelReduction { partial in
                    // GLM's partials are its projections' bfloat16 outputs: they
                    // cross as they are and the sealed sum adds them in float32,
                    // rounding once (`partialsTransport`).
                    group.allSum(partial)
                }
                loaded = value; retired = value
                Memory.clearCache()
                stageResidency = try ClusterStageResidency(bytes: try QwenLongPrefillCheckedBytes.sum([
                    Memory.activeMemory, requestReserve, bufferCacheBytes]))
                if bufferCacheBytes > 0 { Memory.cacheLimit = bufferCacheBytes; try checked() }
                // Never 0 while on: a rank with no budget would skip the vote its peer takes.
                prefixBudget = prefixEnabled
                    ? max(1, QwenTensorParallelPrefixCache.defaultBudget(activeLoaded: Memory.activeMemory)) : 0
                let loadedIdentity = sha256(try canonicalJSONData([loadAgreement, descriptor.artifactAggregateSHA256,
                    String(shardBytes), String(mtpBytes)]))
                _ = try requireQwenLongPrefillReadinessDigest(collective: collective,
                    material: { .residentLoaded(agreementFingerprint: loadedIdentity) },
                    disagreementMessage: "GLM tensor-parallel peers did not load matching shards",
                    scope: .session(.loadedReady, "glm-tensor-parallel-loaded"), check: checked)
                log("darkbloom-tensor-parallel-load-v1 rank=\(collective.rank) plan=\(planName) shares=1-1"
                    + " shard_bytes=\(shardBytes) source_bytes=\(inventory.entries.values.reduce(0) { $0 + $1.bytes })"
                    + " tensors=\(inventory.entries.count) load_ns=\(DispatchTime.now().uptimeNanoseconds - started)"
                    + " cut=\(descriptor.cut) launch_cut=\(configuration.stageCut) micro_batches=\(Self.prefillMicroBatches) sealed=1 buffer_cache=\(bufferCacheBytes) wired_limit=\(stageResidency?.receipt.appliedBytes ?? 0)"
                    + " mtp_depth=\(Self.mtpDepth) mtp_bytes=\(mtpBytes) prefix_budget=\(prefixBudget) lanes=\(lanes.lanes)")
            }
            guard let stage = loaded, (loadedMTP != nil) == (Self.mtpDepth > 0) else {
                throw ProbeError("GLM tensor-parallel load returned no stage or NextN layer")
            }
            try control.loaded()
            return GLM5NextTensorParallelResidentRuntime(configuration: configuration, descriptor: descriptor,
                control: control, collective: collective, group: group, codec: codec, stage: stage, mtp: loadedMTP,
                residency: stageResidency, requestReserveBytes: requestReserve, loadAgreement: loadAgreement, linkProbe: probe,
                planSHA256: planSHA256, lanes: lanes, prefix: GLM5NextTensorParallelPrefixCache(budgetBytes: prefixBudget))
        } catch {
            let primary = error; control.fail(); loaded = nil; loadedMTP = nil
            do {
                try MLX.withError { nativeError in
                    Stream.gpu.synchronize(); Stream.cpu.synchronize(); Memory.clearCache(); try nativeError.check()
                }
                guard retired == nil, retiredMTP == nil else {
                    throw ProbeError("GLM tensor-parallel failed-load stage remains retained")
                }
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

    /// Request memory speculative decode adds on one rank, beside both
    /// pipeline ranks' request budgets (0 when `depth` is 0):
    /// - the NextN layer's history, priced as one of the text model's DSA
    ///   layers is (`GLM5NextRequestStateBudget`): three float32-bounded
    ///   histories and validity over twice the context, three copies, plus one
    ///   chunk of new columns;
    /// - its work: the SDK's bound for one history observation of a chunk's
    ///   rows (`GLM5NextMTPExecution.memoryPlan`; prompt priming runs in
    ///   pieces of at most a chunk), or for a round's proposal, one bound per
    ///   primed row and one per continuation, whichever is larger;
    /// - the captured verification windows: every linear-attention layer keeps
    ///   each window token's state until the commit adopts one, and the state
    ///   adopted last round (a lazy copy out of its window) and this round's
    ///   window coexist. Full heads, as the request budgets charge KDA state.
    /// A window's logits (`[1 + depth, vocabulary]`) are far inside the final
    /// stage's chunk-logits allowance already in the budget.
    static func speculationRequestBytes(configuration c: GLM5NextTextConfiguration,
                                        profile: QwenLayerStageGenerationProfile, depth: Int,
                                        executionPolicy: GLM5NextExecutionPolicy,
                                        allocationBound: (Int) throws -> Int = QwenResidentResourceEnvironment.allocationBound)
        throws -> Int {
        guard depth > 0 else { return 0 }
        typealias Bytes = QwenLongPrefillCheckedBytes
        func native(_ bytes: Int, copies: Int = 1) throws -> Int {
            try Bytes.product([allocationBound(bytes), copies])
        }
        let chunk = profile.maximumChunkTokens
        let capacity = max(256, try Bytes.product([2, profile.maximumContextTokens]))
        let history = try Bytes.sum([c.kvLoraRank * 4, c.indexHeadDim * 4, c.indexHeadDim * 4, 1].map { width in
            try Bytes.sum([native(Bytes.product([capacity, width]), copies: 3), native(Bytes.product([chunk, width]))])
        })
        let plan = try GLM5NextMTPExecution.memoryPlan(configuration: c, maximumInputs: profile.maximumContextTokens,
            limits: .init(maximumPrefillTokens: chunk, maximumDraftTokens: depth), executionPolicy: executionPolicy)
        func bytes(_ buffers: [CBv2MTPFixedBufferSpec]) throws -> Int {
            try Bytes.sum(buffers.map { try native($0.logicalBytes, copies: $0.allocationCount) })
        }
        let work = max(try bytes(plan.historyWorkBuffers), try Bytes.sum([
            Bytes.product([bytes(plan.draftWorkBuffers), depth + 1]),
            Bytes.product([bytes(plan.continuationWorkBuffers), depth - 1])]))
        let linear = c.linearAttention
        let kdaLayers = c.layerTypes.filter { $0 == .linearAttention }.count
        let recurrent = try Bytes.product([depth + 1, linear.numHeads, linear.headDim, linear.headDim, 4])
        let convolution = try Bytes.product([depth + 1, 3, linear.numHeads, linear.headDim,
            linear.shortConvKernelSize, 4])
        let windows = try Bytes.product([Bytes.sum([native(recurrent, copies: 2), native(convolution, copies: 2)]),
            kdaLayers])
        return try Bytes.sum([history, work, windows])
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
                 codec: QwenTensorParallelSealCodec?, stage: GLM5NextTextStage, mtp: GLM5NextMTP?,
                 residency: ClusterStageResidency?,
                 requestReserveBytes: Int, loadAgreement: String, linkProbe: ClusterWorkerLinkProbe?,
                 planSHA256: String, lanes: QwenBatchSettings, prefix: GLM5NextTensorParallelPrefixCache) {
        self.prefix = prefix; self.lanes = lanes
        self.configuration = configuration; self.descriptor = descriptor; self.control = control
        self.collective = collective; self.group = group; self.codec = codec; self.stage = stage; self.mtp = mtp
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

    /// Gives back what this idle rank holds beyond its weights
    /// (`ClusterIdleMemory`): MLX's freed-buffer cache, and the prompt-prefix
    /// entries too while the host is `underPressure` (the vote then restores
    /// nothing until both ranks hold a boundary again). Nothing while a
    /// request or any batch lane is reserved, started or running. Returns the
    /// bytes given back.
    public func releaseIdleMemory(underPressure: Bool) throws -> Int {
        guard operation.try() else { throw ProbeError("Resident native operation is already active") }
        defer { operation.unlock() }
        guard control.available, reservation == nil, laneBook.isEmpty, stage != nil else { return 0 }
        let cached = Memory.cacheMemory, held = Memory.activeMemory + cached, entries = prefix.count
        let dropped = underPressure ? prefix.sweep() : 0
        ClusterIdleMemory.releaseFreedBuffers()
        let released = max(0, held - Memory.activeMemory - Memory.cacheMemory)
        // Keep-warm pulses leave a few bytes in the cache between ticks.
        if released >= 1 << 20 {
            log("darkbloom-idle-release-v1 rank=\(collective.rank) released_bytes=\(released) freed_buffer_bytes=\(cached)"
                + " prefix_entries_dropped=\(underPressure ? entries : 0) prefix_bytes_dropped=\(dropped)"
                + " prefix_entries=\(prefix.count) prefix_bytes=\(prefix.bytesInUse) pressure=\(underPressure ? 1 : 0)"
                + " active_bytes=\(Memory.activeMemory)")
        }
        return released
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
            // What an idle rank keeps for the next request gives way first.
            try prefix.yieldingMemory { try Self.requireLiveMemory(bytes: requestReserveBytes) }
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
        try ClusterCommittedTokenChannel.answering(onCommittedToken) { try start(requestID: requestID, tokens: $0) }
    }

    /// As `start(requestID:onCommittedToken:)`, with the owner's answer to
    /// each token read one step (or round) later, after the next one was
    /// submitted: the answer's pipe round trip (about 1.6 ms a token through
    /// the owner) then overlaps the next step's encoding and GPU time.
    public func start(requestID: UUID, tokens channel: ClusterCommittedTokenChannel) throws
        -> QwenResidentGenerationCompletion {
        guard operation.try() else { throw ProbeError("Resident native operation is already active") }
        defer { operation.unlock() }
        guard let reserved = reservation, reserved.request.requestID == requestID else {
            throw ProbeError("Resident start has no matching reservation")
        }
        do {
            let value = try QwenResidentRequestPublication.run(control: control, lifecycle: lifecycle,
                identity: .init(requestID: requestID, epoch: requestID, recordedRequestFingerprint: reserved.request.fingerprint),
                deadline: reserved.deadline, body: {
                    try autoreleasepool { try generate(reserved, channel: channel) }
                }, prepare: { $0 })
            collective.logDataPlaneStatus()
            reservation = nil
            return value
        } catch {
            // The peer may hold something else now.
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
                    weak var released: GLM5NextTextStage?
                    weak var releasedMTP: GLM5NextMTP?
                    released = stage; releasedMTP = mtp; reservation = nil; laneBook.clear(); stage = nil; mtp = nil
                    guard released == nil, releasedMTP == nil else {
                        throw ProbeError("GLM tensor-parallel stage remains retained")
                    }
                    try residency?.end(); residency = nil
                    Memory.clearCache(); try error.check()
                }
            }
            control.closed()
            processLeaseOwned = false; QwenResidentProcessLease.shared.release()
        } catch { control.fail(); throw error }
    }

    deinit { if processLeaseOwned { control.fail() } }

    // MARK: - One request's arithmetic (the solo path and every lane)

    /// Prefill chunks of a request whose own chunk is `requestChunk`: the
    /// largest multiple of it within `prefillChunkTokens`.
    /// Command-buffer commit limits of decode steps, MTP rounds and lane
    /// rounds on the thread that encodes them. The owner's rank guard caps a
    /// buffer at 16 operations (`MLX_MAX_OPS_PER_BUFFER`), which on a decode
    /// step of ~1,400 operations is ~85 buffers, each a GPU gap of about 10 us:
    /// 13.24 ms a TP2 step at 16 against 12.56 at 100 (pair-measured, tokens
    /// identical; 400 gains nothing more). The size bound stays lifted, as the
    /// worker sets it for tensor parallel (`WorkerCommandBufferBudget`): every
    /// MoE launch takes its whole expert bank as an input. Prefill keeps the
    /// rank's limits. Synchronization only: results never depend on the
    /// partitioning.
    static let decodeCommandBuffers = GPU.CommandBufferLimits(operations: 100, megabytes: 1 << 20)

    static func prefillChunk(requestChunk: Int) -> Int {
        let requestChunk = max(1, requestChunk)
        return max(requestChunk, (prefillChunkTokens / requestChunk) * requestChunk)
    }

    /// The prompt boundary kept for prefixes: the last whole chunk before the
    /// final token (0 with the cache off).
    static func prefixKeepAt(promptCount: Int, chunk: Int, prefixEnabled: Bool) -> Int {
        prefixEnabled ? ((promptCount - 1) / chunk) * chunk : 0
    }

    /// Where the prefill frame that starts at `offset` ends. The chunks are
    /// the one grid every request prefills on, alone or in a lane: a bulk
    /// chunk while it ends at or before the boundary kept for prefixes (or the
    /// prompt's end), else the next chunk boundary, each as
    /// `prefillMicroBatches` micro-batches. A frame is one chunk, or with
    /// `merging` the first graph of `GLM5NextTensorParallelPrefillPlan` from
    /// `offset` (consecutive chunks up to `mergedPrefillTokens`); either way
    /// every micro-batch and so the frames' arithmetic is the same.
    static func prefillFrameEnd(offset: Int, promptCount: Int, chunk: Int, keepAt: Int, merging: Bool = false) -> Int {
        GLM5NextTensorParallelPrefillPlan.make(promptCount: promptCount, start: offset, chunkTokens: chunk,
            keepAt: keepAt, bulkTokens: bulkPrefillChunkTokens, microBatches: prefillMicroBatches,
            mergedTokens: merging ? mergedPrefillTokens : 0, microBatchTokens: prefillMicroBatchTokens,
            coalescing: merging).chunks[0].end
    }

    /// A request as it begins on this rank, after both ranks checked they hold
    /// it, voted for its prompt prefix and restored it (or start cold).
    struct OpenedRequest {
        let cache: GLM5NextTextStageCache
        /// Prompt tokens restored from the prefix cache.
        let start: Int
        let speculation: GLM5NextTensorParallelSpeculation?
        let chunk: Int
        let keepAt: Int
    }

    /// Opens `request` (collective: a digest agreement and, with the prefix
    /// cache on and a prompt longer than a chunk, one prefix vote).
    func openRequest(_ request: QwenLayerStageGenerationRequest, stage: GLM5NextTextStage) throws -> OpenedRequest {
        let rank = collective.rank
        guard try group.digestsEqual(QwenTensorParallelResidentRuntime.digest64(request.fingerprint + "|" + loadAgreement)) else {
            throw ProbeError("GLM tensor-parallel ranks were given different requests")
        }
        let chunk = Self.prefillChunk(requestChunk: request.chunkSize)
        let prompt = request.promptTokenIDs
        // Greedy requests decode speculatively, and so do sampled ones whose
        // transforms do not depend on their history (as in the product; bias
        // and penalties decode one token per step). Every request primes the NextN
        // history over its prompt (cheap: no attention, MoE or readout), so
        // every prefix entry carries the history at its boundary.
        let speculation = try mtp.map {
            try GLM5NextTensorParallelSpeculation(mtp: $0, depth: Self.mtpDepth, rank: rank, ranks: collective.size,
                primeRows: descriptor.profile.maximumChunkTokens, agree: { [group] in group.allSum($0) })
        }
        // Prompt prefix: the longest chunk boundary both ranks hold.
        let scope = loadAgreement
        var cache = stage.newCache(), start = 0
        if prefix.enabled, prompt.count > chunk {
            let candidates = QwenTensorParallelPrefixCache.candidates(promptCount: prompt.count, chunk: chunk)
            let held = prefix.heldBoundaries(scope: scope, prompt: prompt, chunk: chunk)
            if let agreed = try QwenTensorParallelPrefixCache.agree(held: held, group: group, candidates: candidates) {
                guard let restored = prefix.restore(scope: scope, prompt: prompt, length: agreed) else {
                    throw ProbeError("GLM tensor-parallel prefix both ranks voted for is gone")
                }
                cache = restored.cache; start = agreed
                try speculation?.restore(restored.mtp)
            }
        }
        return OpenedRequest(cache: cache, start: start, speculation: speculation, chunk: chunk,
            keepAt: Self.prefixKeepAt(promptCount: prompt.count, chunk: chunk, prefixEnabled: prefix.enabled))
    }

    /// One prefill frame `offset ..< end` of `prompt` (`prefillFrameEnd`): its
    /// chunks' micro-batches in one stage forward, the NextN priming in its
    /// evaluation, and the prompt prefix kept when a chunk ends at `keepAt`
    /// (inside the frame or at its end). `merging`: the frame is a merging
    /// one (`prefillFrameEnd(merging: true)`), whose chunks may share
    /// micro-batches. The final frame returns the last row's logits and
    /// hidden row; `stored` is the kept boundary.
    func runPrefillFrame(_ prompt: [Int], offset: Int, end: Int, opened: OpenedRequest, stage: GLM5NextTextStage,
                         merging: Bool = true)
        throws -> (final: (logits: MLXArray, lastHidden: MLXArray)?, stored: Int?) {
        let frame = try GLM5NextTensorParallelPrefillPlan.frame(start: offset, end: end, promptCount: prompt.count,
            chunkTokens: opened.chunk, keepAt: opened.keepAt,
            bulkTokens: Self.bulkPrefillChunkTokens, microBatches: Self.prefillMicroBatches,
            microBatchTokens: Self.prefillMicroBatchTokens, coalescing: merging)
        let result = try GLM5NextTensorParallelPrefillPlan.run(frame, stage: stage, cache: opened.cache, prompt: prompt,
            speculation: opened.speculation)
        if let kept = result.kept {
            prefix.store(scope: loadAgreement, prompt: prompt, length: kept.end, cache: kept.cache, mtp: kept.history)
        }
        return (result.final, result.kept?.end)
    }

    /// One small sealed reduction per step: [token rank 0, token rank 1,
    /// stop rank 0, stop rank 1]. Greedy: both ranks put their own choice
    /// and must agree. Sampled: rank 0 draws, rank 1 puts 0 and adopts it.
    func choose(_ row: MLXArray, sampler: QwenStageTokenSampler?, stop: Float) -> MLXArray {
        let rank = collective.rank
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

    /// The agreed token of an evaluated `choose`.
    static func agreedToken(_ agreed: [Float], sampled: Bool) throws -> Int {
        guard agreed.count == 4 else { throw ProbeError("GLM tensor-parallel selection has a wrong shape") }
        if !sampled, agreed[0] != agreed[1] {
            throw ProbeError("GLM tensor-parallel ranks chose different greedy tokens")
        }
        return Int(agreed[0])
    }

    /// Sampled MTP rounds: rank 0 draws the keyed target sample at every
    /// window column, at output indexes from the sampler's committed count.
    /// Rank 1 puts the window's argmax, which the agreement ignores: its slot
    /// must depend on the window's logits, or the round's one evaluation may
    /// run the agreement sum before the layer sums on rank 1 only, and the
    /// ranks' sums no longer pair up. Nil for greedy requests (the argmax).
    func verificationDraw(_ sampler: QwenStageTokenSampler?) -> ((MLXArray) -> MLXArray)? {
        let rank = collective.rank
        return sampler.map { sampler in
            { logits in
                (rank == 0 ? sampler.verify(logits) ?? argMax(logits, axis: -1) : argMax(logits, axis: -1))
                    .asType(.float32)
            }
        }
    }

    // MARK: - One request

    private func generate(_ reserved: Reserved, channel: ClusterCommittedTokenChannel) throws
        -> QwenResidentGenerationCompletion {
        guard let stage else { throw ProbeError("Resident model already released") }
        let request = reserved.request, rank = collective.rank
        let opened = try openRequest(request, stage: stage)
        let sampler = request.sampler
        let prompt = request.promptTokenIDs
        var lastCheck: UInt64 = 0
        func localStop() -> Bool {
            if (try? control.check(deadline: reserved.deadline)) == nil { return true }
            let now = DispatchTime.now().uptimeNanoseconds
            if now - lastCheck >= 250_000_000 {
                lastCheck = now
                if (try? prefix.yieldingMemory({ try Self.requireLiveMemory(bytes: 0) })) == nil { return true }
            }
            return false
        }
        let speculation = opened.speculation, cache = opened.cache, start = opened.start
        // Prefill from `start` in chunks aligned to the boundaries; keep the
        // last whole boundary before the final token.
        var logits: MLXArray?, lastHidden: MLXArray?
        var offset = start, stored: [Int] = []
        while offset < prompt.count {
            let end = Self.prefillFrameEnd(offset: offset, promptCount: prompt.count, chunk: opened.chunk,
                keepAt: opened.keepAt, merging: true)
            let frame = try runPrefillFrame(prompt, offset: offset, end: end, opened: opened, stage: stage)
            if let final = frame.final { logits = final.logits; lastHidden = final.lastHidden }
            if let at = frame.stored { stored.append(at) }
            offset = end
        }
        guard let firstLogits = logits else { throw ProbeError("GLM tensor-parallel prefill produced no logits") }

        func choose(_ row: MLXArray, stop: Float) -> MLXArray { self.choose(row, sampler: sampler, stop: stop) }
        func token(_ agreed: [Float]) throws -> Int { try Self.agreedToken(agreed, sampled: sampler != nil) }
        // Decode encodes under `decodeCommandBuffers` (prefill keeps the rank's own limits).
        var previousOperations: Int32 = 0, previousMegabytes: Int32 = 0
        mlx_metal_set_thread_command_buffer_limits(Int32(Self.decodeCommandBuffers.operations),
            Int32(Self.decodeCommandBuffers.megabytes), &previousOperations, &previousMegabytes)
        defer { mlx_metal_set_thread_command_buffer_limits(previousOperations, previousMegabytes, nil, nil) }
        var tokens: [Int] = []
        var finish: ClusterWorkerFinishReason = .length
        var clientStopped = false
        var stopKeep: Float = 0
        // Rank 0 publishes each token at once and reads the owner's answer to
        // it after the next step or round was submitted, before publishing
        // the next token. A stop answer is acted on one step later: the extra
        // step is computed and never published.
        var unanswered = false
        func readAnswer() throws {
            guard unanswered else { return }
            unanswered = false
            if try !channel.answer(), stopKeep == 0 { clientStopped = true; stopKeep = Float(tokens.count) }
        }
        /// Commits one agreed token on this rank (and publishes it on rank 0);
        /// the request's own end (EOS or length) at it, else nil.
        func commit(_ value: Int) throws -> ClusterWorkerFinishReason? {
            tokens.append(value)
            if rank == 0 {
                try channel.publish(tokens.count - 1, value, prompt.count + tokens.count - 1); unanswered = true
            }
            switch QwenTensorParallelStopRule.outcome(isStopToken: request.stopTokenIDs.contains(value),
                                                      committed: tokens.count, outputCount: request.outputCount, wanted: true) {
            case .eos: return .eos
            case .length: return .length
            case .clientStop, .proceed: return nil
            }
        }
        if let speculation, sampler?.admitsSpeculativeVerification ?? true, let lastHidden {
            // The first token is agreed as a plain step's; then each round
            // commits 1 to `mtpDepth + 1` agreed tokens. What a round builds
            // and when the loop ends follow from agreed tokens only, so both
            // ranks submit the same sums. A round's tokens are committed
            // while the next round runs (`whileRunning`), unless they end the
            // request. A rank that stopped (client stop, cancel, deadline,
            // memory) stops committing, still ends where the other rank
            // would, and carries its flag in the next round it submits.
            let first = try token(choose(firstLogits, stop: 0).asArray(Float.self))
            sampler?.commit(first)
            // Sampled: rank 0 draws the keyed target sample at every window
            // column, at output indexes from the sampler's committed count
            // (rank 1's slot depends on the logits: `verificationDraw`).
            let draw = verificationDraw(sampler)
            try speculation.begin(carry: first, lastHidden: lastHidden)
            var agreedCount = 1, last = first, fresh: [Int] = []
            /// Takes one agreed token; true when the request ends at it.
            func take(_ value: Int, counted: Int) throws -> Bool {
                if stopKeep == 0 { try readAnswer() }
                guard stopKeep == 0 else {
                    return request.stopTokenIDs.contains(value) || counted >= request.outputCount
                }
                if let end = try commit(value) { finish = end; return true }
                return false
            }
            var ended = try take(first, counted: 1)
            rounds: while !ended {
                let taken = agreedCount
                let round = try speculation.round(stage: stage, cache: cache, last: last,
                    window: min(speculation.depth, request.outputCount - agreedCount - 1), stop: stopKeep, draw: draw,
                    whileRunning: {
                        for (index, value) in fresh.enumerated() {
                            _ = try take(value, counted: taken - fresh.count + index + 1)
                        }
                        if stopKeep == 0, localStop() { stopKeep = Float(tokens.count) }
                    })
                if let keep = round.stops.filter({ $0 > 0 }).min() {
                    tokens = Array(tokens.prefix(Int(keep)))
                    finish = .clientStop; break
                }
                fresh = round.tokens; last = fresh[fresh.count - 1]; agreedCount += fresh.count
                sampler?.commitRound(fresh)
                // Tokens that end the request are taken now (no next round).
                let ends = fresh.indices.contains {
                    request.stopTokenIDs.contains(fresh[$0]) || agreedCount - fresh.count + $0 + 1 >= request.outputCount
                }
                if ends {
                    for (index, value) in fresh.enumerated()
                    where try take(value, counted: agreedCount - fresh.count + index + 1) { break rounds }
                    ended = true
                }
            }
        } else {
            // Greedy steps are built one ahead: step k+1 is submitted before step
            // k's choice is read. A sampled step is built after its token is known
            // (the sampler draws at the output index with the history up to it).
            let pipelined = sampler == nil
            var current = choose(firstLogits, stop: 0)
            asyncEval(current)
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
                // The answer to the last token arrived while this step was encoded.
                if stopKeep == 0 { try readAnswer() }
                let agreed = current.asArray(Float.self)
                let value = try token(agreed)
                let flags = [agreed[2], agreed[3]].filter { $0 > 0 }
                if let keep = flags.min() {
                    tokens = Array(tokens.prefix(Int(keep)))
                    finish = .clientStop; break
                }
                if stopKeep == 0 {
                    sampler?.commit(value)
                    if let end = try commit(value) { finish = end; break steps }
                    if localStop() { stopKeep = Float(tokens.count) }
                }
                if !pipelined, index + 1 < request.outputCount { pending = try step(from: current, stop: stopKeep) }
                guard let next = pending else { break }
                current = next; pending = nil
            }
            // A step both ranks submitted is evaluated by both, so its reductions meet.
            if let pending { eval(pending) }
        }
        // The owner answers every published token, the last one too. A stop
        // answer to a token the request ended at changes nothing.
        if unanswered {
            unanswered = false
            if try !channel.answer(), finish == .clientStop { clientStopped = true }
        }
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
            + " prompt=\(prompt.count) reused=\(start) stored=\(stored.map(String.init).joined(separator: "_"))"
            + " prefix_entries=\(prefix.count) prefix_bytes=\(prefix.bytesInUse) output=\(tokens.count) finish=\(finish.rawValue)"
            + " sampled=\(sampler == nil ? 0 : 1) frames=\(codec?.sealedFrames ?? 0) key_generation=\(codec?.keyGeneration ?? 0)"
            + " mtp_rounds=\(speculation?.rounds ?? 0) mtp_accepted=\(speculation?.acceptedTokens ?? 0)"
            + " mtp_proposed=\(speculation?.proposedTokens ?? 0)")
        return QwenResidentGenerationCompletion(requestID: request.requestID, finishReason: finish,
            selectedTokenIDs: tokens, completedFrames: tokens.count, committedTokens: prompt.count + tokens.count,
            tokenChainSHA256: sha256(try canonicalJSONData(tokens.map { String($0) })), bothRequestStatesRetired: true,
            reusedPromptTokens: start, storedPromptFrontiers: stored)
    }
}
