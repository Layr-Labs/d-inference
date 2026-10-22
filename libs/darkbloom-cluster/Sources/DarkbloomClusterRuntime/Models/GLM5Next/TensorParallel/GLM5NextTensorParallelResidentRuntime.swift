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
/// position's token, the proposals and the stop flags. So do sampled
/// requests, verifying against keyed target draws with proposals coupled to
/// them (`coupledDraftSharpness`); logit bias and penalties are replayed over
/// each round's proposals (`QwenStageTokenSampler.verifyRound`).
///
/// Image and video input (`ClusterGLMMedia`) is served as the single-Mac
/// product serves it (`GLM5NextTensorParallelMedia`), alone or in a lane:
/// rank 0 holds the vision tower and prepares the media's patches from its
/// reservation on, off the executor; when the request opens, rank 0 runs the
/// tower and both ranks agree the features with one sealed sum per frame; the
/// prefill splices them over the media positions and primes the NextN history
/// with them, and the request decodes speculatively as text does, with no
/// prefix reuse.
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
    /// A request prefills consecutive chunks together in one graph (frame),
    /// up to this many tokens (beside decoding lanes only in layer slices,
    /// `lanePrefillSliceMilliseconds`)
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
    /// While other lanes decode, a lane's prefill frame runs in layer slices
    /// of about this long, one a step, each followed by every decoding lane's
    /// unit (`GLM5NextTensorParallelPrefillPlan.Slices`), so no decoding lane
    /// waits longer than a slice for its next round, and frames merge chunks
    /// (up to `mergedPrefillTokens`) beside decoding lanes too. A slice builds
    /// the frame's next layers for every micro-batch exactly as the whole
    /// frame does: tokens and caches are unchanged. nil: frames run whole,
    /// merging only while no lane decodes (a decoding lane then waits a whole
    /// 8,192-token chunk, about 2 s).
    static let lanePrefillSliceMilliseconds: Double? = 500
    /// The pair's prefill compute per prompt token (merged frames, 31.5K:
    /// 3,973 tok/s), which sizes a slice; only timing depends on it.
    static let prefillMillisecondsPerToken = 0.252
    /// Lanes still prefilling take frames shortest remaining prompt first
    /// (ties: join order), so a short request does not wait for a long one's
    /// whole prompt; a frame in progress always finishes first. False: join
    /// order. Either way each lane's frames are its own.
    static let lanePrefillShortestFirst = true

    /// The layers of a frame's next slice, from `built` of `layers`: the
    /// frame's rest without `slicing`, else the next of the frame's slices,
    /// as many as its estimated time needs at `lanePrefillSliceMilliseconds`,
    /// with near-equal layer counts. Both ranks derive it.
    static func prefillSlice(from built: Int, layers: Int, tokens: Int, slicing: Bool) -> Range<Int> {
        guard slicing, let budget = lanePrefillSliceMilliseconds, budget > 0, built < layers else { return built ..< layers }
        let estimate = Double(tokens) * prefillMillisecondsPerToken
        let slices = min(layers, max(1, Int((estimate / budget).rounded(.up))))
        return built ..< ((1 ... slices).lazy.map { $0 * layers / slices }.first { $0 > built } ?? layers)
    }

    /// A sliced frame's held arrays between slices: every micro-batch's
    /// residual streams and pending mHC expand (`[T, hcMult + 1, hidden]`
    /// activations, `post`/`comb` in float32), at the longest frame. Held
    /// while other lanes' units run, so admission charges it beside the
    /// largest forward's transients.
    static func prefillFrontierBytes(configuration c: GLM5NextTextConfiguration) throws -> Int {
        guard lanePrefillSliceMilliseconds != nil else { return 0 }
        return try QwenLongPrefillCheckedBytes.product([mergedPrefillTokens,
            try QwenLongPrefillCheckedBytes.sum([(c.hcMult + 1) * c.hiddenSize * 2, (c.hcMult + c.hcMult * c.hcMult) * 4])])
    }
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
    /// The media contract this runtime serves; bound into the load agreement.
    /// Rank 0 holds the vision tower whole (1.13 GB of bfloat16 weights for
    /// the registered artifact, charged to its load gate); rank 1 holds none.
    static let mediaContract = ClusterGLMMedia.contract
    /// A sampled request draws every NextN proposal with its own sampler and
    /// the keyed noise of the output index the proposal is for (coupled
    /// drafting, `GLM5NextTensorParallelSpeculation`), from the NextN logits
    /// times this factor: 1 applies the target's own race to the draft's
    /// distribution; above 1 sharpens a draft less confident than the target;
    /// infinity proposes the NextN argmax (the rule before coupling). A
    /// request with bias or penalties takes 1 unless it is infinite. Every
    /// committed token stays the target's draw from its window logits at any
    /// value; it moves acceptance (and with it where rounds end).
    static let coupledDraftSharpness: Float = 1
    /// Rank 0 of a stateless sampled request also scores other proposal rules
    /// on every verified round's first proposal: the argmax, then the coupled
    /// draw at each of `probedDraftSharpness`. Its kept counts are logged
    /// (`mtp_probe`); one more small sampling pass per round, enqueued after
    /// the round's result is read. Diagnostic: proposals and tokens never change.
    static let probesDraftRules = true
    static let probedDraftSharpness: [Float] = [1, 1.5, 2, 3]

    /// The request log line's proposal fields: the rule, kept and made
    /// proposals per position, and the draft probe's kept counts.
    static func proposalFields(_ speculation: GLM5NextTensorParallelSpeculation?,
                               sampler: QwenStageTokenSampler?) -> String {
        guard let speculation else { return "" }
        let rule = sampler.map { $0.admitsSpeculativeVerification ? "coupled\(coupledDraftSharpness)" : "replayed" }
        var fields = " mtp_draft=\(rule ?? "argmax")"
            + " mtp_accepted_by_position=" + speculation.acceptedByPosition.map(String.init).joined(separator: "-")
            + " mtp_proposed_by_position=" + speculation.proposedByPosition.map(String.init).joined(separator: "-")
        if let hits = speculation.draftProbeHits() {
            fields += " mtp_probe_rounds=\(speculation.probedRounds) mtp_probe=" + hits
        }
        return fields
    }

    /// The rules `probesDraftRules` scores, named `argmax` and `c<sharpness>`.
    static func draftProbe(_ sampler: QwenStageTokenSampler) -> GLM5NextTensorParallelSpeculation.DraftProbe {
        .init(names: ["argmax"] + probedDraftSharpness.map { "c\($0)" }) { logits in
            let wide = logits.asType(.float32)
            let greedy = argMax(wide[0..., -1, 0...], axis: -1).reshaped(1).asType(.int32)
            let coupled = sampler.draft(concatenated(probedDraftSharpness.map { wide * $0 }, axis: 0), offset: 0)
            return concatenated([greedy] + (coupled.map { [$0.reshaped(-1).asType(.int32)] } ?? []), axis: 0)
        }
    }

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
    /// Rank 0's vision tower (`mediaContract`); nil on rank 1.
    var vision: GLM5NextStageVision?
    private var residency: ClusterStageResidency?
    /// What a request costs this rank at its own context
    /// (`GLM5NextTensorParallelRequestCharge`): `reserve` and `reserveLane`
    /// admit by it; READY's capacity is its value at the profile's longest.
    let requestCharge: GLM5NextTensorParallelRequestCharge
    /// The charge of the memory plan's request, which the LOAD gate admitted.
    let requestReserveBytes: Int
    /// The longest context this rank's gate admits now (READY, then each
    /// keep-warm answer: `refreshServingContext`).
    private(set) var servingContextTokens: Int?
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
        /// The request's images and video (rank 0 prepares them meanwhile).
        let media: GLM5NextTensorParallelMedia?
    }

    // MARK: - Load

    public static func load(_ configuration: QwenResidentLoadConfiguration,
                            qualification: QwenResidentQualificationSwitches = .refused,
                            dataPlane credential: ClusterDataPlaneCredential) throws -> GLM5NextTensorParallelResidentRuntime {
        let entered = DispatchTime.now().uptimeNanoseconds
        let enteredUnixMilliseconds = Int64(Date().timeIntervalSince1970 * 1000)
        let environment = ProcessInfo.processInfo.environment
        try qualification.admit(environment: environment)
        let lanes = try QwenBatchSettings.fromEnvironment(environment)
        let path = try GLM5NextTensorParallelLoadPath.resolved(environment)
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
        let profile = descriptor.profile
        let text = descriptor.configuration.textConfig
        guard Self.mtpDepth == 0 || (text.numNextNPredictLayers == 1
                && Self.mtpDepth <= GLM5NextMTP.maximumProposalDepth
                && (Self.mtpDepth == 1 || text.indexShareForMTPIteration)) else {
            throw ProbeError("GLM tensor-parallel speculative depth \(Self.mtpDepth) is unsupported by this model")
        }
        // Paged KV histories (`GLM5NextTensorParallelPagedKV.swift`), bound into the agreement.
        let pagedKV = try Self.pagedKV(environment)
        _ = try Self.pagedRetainBytes(environment)
        // MLX's device record, read here first; the metadata thread's quotes read it too.
        let maximumBufferBytes = GPU.deviceInfo().maxBufferSize
        let roots = GLM5NextArtifactLoadRoots()
        // The inventory, the request charge and the gate's bytes (and on the
        // prepared path the owner whose single read loads the shard) come from
        // the checkpoint's metadata alone: worked out on a thread of their own
        // while this one brings the link up, and joined before the intent.
        let metadataWork = GLM5NextTensorParallelBackground {
            try GLM5NextTensorParallelLoadMetadata(spec: spec, descriptor: descriptor, directory: directory,
                rank: configuration.rank, buildSHA256: configuration.identity.peers.map(\.buildSHA256), path: path,
                roots: roots, pagedKV: pagedKV, maximumBufferBytes: maximumBufferBytes)
        }
        var phases = GLM5NextTensorParallelLoadPhases(since: entered, startedUnixMilliseconds: enteredUnixMilliseconds)
        phases.mark("setup")
        // The prefix cache votes in a reduction of its own: both ranks must
        // have it on, or both off (`DARKBLOOM_CLUSTER_PREFIX_CACHE=off`).
        let prefixEnabled = QwenStagePrefixCache.fromEnvironment(environment).enabled
        let control = QwenResidentControl(deadline: configuration.deadlineUptimeNanoseconds, lease: configuration.lease)
        try QwenResidentProcessLease.shared.acquire()
        var loaded: GLM5NextTextStage?
        var loadedMTP: GLM5NextMTP?
        var loadedVision: GLM5NextStageVision?
        weak var retired: GLM5NextTextStage?
        weak var retiredMTP: GLM5NextMTP?
        weak var retiredVision: GLM5NextStageVision?
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
                GLM5NextTensorParallelSpeculation.agreementName, String(mtpDepth), mediaContract,
                descriptor.fingerprint, identity.membershipEpoch.uuidString.lowercased(), jaccl.fingerprint,
                collective.transport.rawValue, configuration.allocatorPolicy.rawValue,
                "glm5-next-tensor-parallel-prefix-v1", prefixEnabled ? "on" : "off"]
                + Self.laneAgreementFields(lanes) + Self.pagedKVAgreementFields(pagedKV)
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
            phases.mark("link")
            let metadata = try metadataWork.join()
            let inventory = metadata.inventory
            var requestCharge = metadata.requestCharge
            let requestReserve = metadata.requestReserve, shardBytes = metadata.shardBytes
            let mtpBytes = metadata.mtpBytes, visionBytes = metadata.visionBytes, mediaCapacity = metadata.mediaCapacity
            phases.mark("metadata")
            phases.note("metadata_thread", metadataWork.finishedUptimeNanoseconds - metadataWork.startedUptimeNanoseconds)
            phases.note("metadata_inventory", metadata.inventoryNanoseconds)
            phases.note("metadata_resources", metadata.resourcesNanoseconds)
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
                phases.mark("intent")
                // The link as this mode uses it, before any weight is read: the
                // planner's measured reduction costs for this pair.
                let measured = try QwenTensorParallelLinkProbe.measure(collective: collective, group: group,
                    hiddenSize: descriptor.configuration.textConfig.hiddenSize,
                    chunkTokens: descriptor.profile.maximumChunkTokens, check: checked)
                probe = measured
                log(QwenTensorParallelLinkProbe.line(measured, rank: collective.rank))
                phases.mark("probe")
                // The live gate admits this rank's shard and the whole request charge before any read.
                try requireLiveMemory(bytes: try QwenLongPrefillCheckedBytes.sum([shardBytes, mtpBytes, visionBytes,
                    requestReserve, bufferCacheBytes]))
                phases.mark("gate")
                // `prepared` (the product): the owner parsed the metadata on the
                // metadata thread and checks every file's SHA-256 in `prepare`, in
                // the one read that also fills this rank's buffers; nothing is
                // built before it matched. `per-tensor`: the owner hashes every
                // file here, after the gate, as before.
                let loader = try metadata.loader ?? GLM5NextArtifactLoader(directory: directory,
                    expectedIdentity: descriptor.artifactIdentity, storage: descriptor.storage, constructionRoots: roots,
                    executionPolicy: descriptor.executionPolicy, verification: path.verification)
                guard GLM5NextArtifactMetadata.fingerprint(loader.inventory) == spec.inventorySHA256 else {
                    throw ProbeError("GLM verified owner differs from the registered inventory")
                }
                let text = loader.configuration.textConfig
                let plan = try GLM5NextTextStagePlan(configuration: text, layers: 0 ..< text.hiddenLayers,
                    shard: try GLM5NextTensorShard(rank: collective.rank, size: collective.size))
                phases.mark("open")
                if path != .perTensor {
                    try autoreleasepool {
                        try loader.prepare(plan: plan, includeMTP: Self.mtpDepth > 0, keepFileCache: path == .prepared)
                    }
                    try checked()
                    phases.mark("read")
                }
                let value = try autoreleasepool { try loader.loadTextStage(plan: plan) }
                value.tensorParallelMicroBatches = Self.prefillMicroBatches
                value.freeze()
                // Every request's DSA and NextN histories live in this rank's page pool.
                if pagedKV {
                    let pool = try value.makeDSAPagePool(pageSize: Self.dsaPageTokens)
                    value.dsaPagePool = pool
                    requestCharge.pagedHistory = .init(pool: pool)
                    // Its kernels compile here, not in the first request's prefill.
                    let warming = DispatchTime.now().uptimeNanoseconds
                    try pool.prewarm()
                    log("darkbloom-glm-paged-prewarm-v1 rank=\(collective.rank)"
                        + " ms=\((DispatchTime.now().uptimeNanoseconds - warming) / 1_000_000)")
                }
                // The NextN layer, whole, bound to the stage's replicated embedding and head.
                let head = Self.mtpDepth > 0 ? try autoreleasepool { try loader.loadMTP(stage: value) } : nil
                head?.freeze()
                loadedMTP = head; retiredMTP = head
                // Rank 0's vision tower, whole, from the same verified loader.
                if collective.rank == 0 {
                    let tower = try GLM5NextStageVision(loader: loader, roots: roots,
                        beforeRead: { _, _ in try checked() }, check: checked)
                    loadedVision = tower; retiredVision = tower
                }
                phases.mark("build")
                try roots.evaluate(value.parameters().flattened().map(\.1)
                    + (head?.parameters().flattened().map(\.1) ?? []))
                Stream.gpu.synchronize(); try checked()
                roots.releaseAfterConfirmedFence()
                try loader.verifyUnchanged()
                phases.mark("evaluate")
                for line in GLM5NextTensorParallelLoadDigest.lines([value] + (head.map { [$0] } ?? []),
                        rank: collective.rank, path: path, environment: environment) {
                    log(line)
                }
                phases.mark("digest")
                try value.installTensorParallelReduction { partial in
                    // GLM's partials are its projections' bfloat16 outputs: they
                    // cross as they are and the sealed sum adds them in float32,
                    // rounding once (`partialsTransport`).
                    group.allSum(partial)
                }
                loaded = value; retired = value
                Memory.clearCache()
                // Residency is a limit, clamped to the product's ceiling: it
                // covers the longest request the profile admits.
                stageResidency = try ClusterStageResidency(bytes: try QwenLongPrefillCheckedBytes.sum([
                    Memory.activeMemory, try requestCharge.bytes(contextTokens: profile.maximumContextTokens),
                    bufferCacheBytes]))
                if bufferCacheBytes > 0 { Memory.cacheLimit = bufferCacheBytes; try checked() }
                // Never 0 while on: a rank with no budget would skip the vote its peer takes.
                prefixBudget = prefixEnabled
                    ? max(1, QwenTensorParallelPrefixCache.defaultBudget(activeLoaded: Memory.activeMemory)) : 0
                phases.mark("residency")
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
                    + " mtp_depth=\(Self.mtpDepth) mtp_bytes=\(mtpBytes) prefix_budget=\(prefixBudget) lanes=\(lanes.lanes)"
                    + " vision_bytes=\(visionBytes) media=\(mediaContract)"
                    + " paged_kv=\(pagedKV ? Self.dsaPageTokens : 0)"
                    + " page_bytes=\(loaded?.dsaPagePool?.pageBytes ?? 0)")
                phases.mark("loaded")
                log(phases.line(rank: collective.rank, path: path))
            }
            guard let stage = loaded, (loadedMTP != nil) == (Self.mtpDepth > 0),
                  (loadedVision != nil) == (configuration.rank == 0) else {
                throw ProbeError("GLM tensor-parallel load returned no stage, NextN layer or vision tower")
            }
            // The longest context the gate admits now, beside the loaded weights.
            let serving = try requestCharge.servingContextTokens(reclaimableBytes: 0)
            log("darkbloom-serving-context-v1 rank=\(collective.rank) tokens=\(serving ?? 0) previous=0 reclaimable=0"
                + " profile=\(profile.maximumContextTokens) reference_charge=\(requestReserve)")
            try control.loaded()
            return try GLM5NextTensorParallelResidentRuntime(configuration: configuration, descriptor: descriptor,
                control: control, collective: collective, group: group, codec: codec, stage: stage, mtp: loadedMTP,
                vision: loadedVision, mediaCapacityBytes: mediaCapacity,
                residency: stageResidency, requestCharge: requestCharge, requestReserveBytes: requestReserve,
                servingContextTokens: serving, loadAgreement: loadAgreement, linkProbe: probe,
                planSHA256: planSHA256, lanes: lanes, prefix: GLM5NextTensorParallelPrefixCache(budgetBytes: prefixBudget))
        } catch {
            let primary = error; control.fail(); loaded = nil; loadedMTP = nil; loadedVision = nil
            do {
                try MLX.withError { nativeError in
                    Stream.gpu.synchronize(); Stream.cpu.synchronize(); Memory.clearCache(); try nativeError.check()
                }
                guard retired == nil, retiredMTP == nil, retiredVision == nil else {
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
        // A sum: the text entries in any order (no name sort).
        try inventory.entries.values.reduce(0) { total, entry in
            guard entry.part == .text else { return total }
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
    /// `contextTokens` (default the profile's longest) and `history` (default
    /// the cache's own doubling) as in `GLM5NextRequestStateBudget`; the NextN
    /// history is charged three times at its bound either way (a round's
    /// checkpoint and two draft appends); a paged one (`.paged`) is pages
    /// the owner charges, and here only one read's gather of it.
    static func speculationRequestBytes(configuration c: GLM5NextTextConfiguration,
                                        profile: QwenLayerStageGenerationProfile, depth: Int,
                                        executionPolicy: GLM5NextExecutionPolicy,
                                        allocationBound: (Int) throws -> Int = QwenResidentResourceEnvironment.allocationBound,
                                        contextTokens: Int? = nil,
                                        history bound: GLM5NextRequestStateBudget.HistoryBound = .geometric)
        throws -> Int {
        guard depth > 0 else { return 0 }
        typealias Bytes = QwenLongPrefillCheckedBytes
        func native(_ bytes: Int, copies: Int = 1) throws -> Int {
            try Bytes.product([allocationBound(bytes), copies])
        }
        let chunk = profile.maximumChunkTokens
        let context = contextTokens ?? profile.maximumContextTokens
        let capacity = try bound.columns(contextTokens: context).capacity
        let history = try Bytes.sum([c.kvLoraRank * 4, c.indexHeadDim * 4, c.indexHeadDim * 4, 1].map { width in
            try Bytes.sum([native(Bytes.product([capacity, width]), copies: bound.isPaged ? 1 : 3),
                native(Bytes.product([chunk, width]))])
        })
        let plan = try GLM5NextMTPExecution.memoryPlan(configuration: c, maximumInputs: min(context, c.maxPositionEmbeddings),
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
                 vision: GLM5NextStageVision?, mediaCapacityBytes: Int,
                 residency: ClusterStageResidency?, requestCharge: GLM5NextTensorParallelRequestCharge,
                 requestReserveBytes: Int, servingContextTokens: Int?, loadAgreement: String, linkProbe: ClusterWorkerLinkProbe?,
                 planSHA256: String, lanes: QwenBatchSettings, prefix: GLM5NextTensorParallelPrefixCache) throws {
        self.prefix = prefix; self.lanes = lanes
        self.configuration = configuration; self.descriptor = descriptor; self.control = control
        self.collective = collective; self.group = group; self.codec = codec; self.stage = stage; self.mtp = mtp
        self.vision = vision
        self.residency = residency; self.requestCharge = requestCharge; self.requestReserveBytes = requestReserveBytes
        self.servingContextTokens = servingContextTokens
        self.loadAgreement = loadAgreement; self.linkProbe = linkProbe
        // The most one request is charged: its context at the profile's
        // longest, plus what one media request may add on this rank (a text
        // request is charged its context alone).
        baseReady = .init(identity: configuration.identity, rank: collective.rank, profile: descriptor.wireProfile,
            executionPlanSHA256: planSHA256,
            requestCapacityBytes: try QwenLongPrefillCheckedBytes.sum([
                try requestCharge.bytes(contextTokens: descriptor.profile.maximumContextTokens), mediaCapacityBytes]),
            dataPlane: collective.workerDataPlane, servingContextTokens: servingContextTokens, linkProbe: linkProbe,
            media: Self.mediaContract)
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
        // Pages nobody holds go back to the pool. Its slabs stay for the next
        // request (one that fits them reserves without allocating or copying
        // a slab) up to the retention cap; above it, or under pressure, they
        // go as before (all of them once no entry holds a page). A
        // reservation's gate takes retained slabs back before it refuses
        // (`yieldingIdleMemory`).
        var slabs = ""
        if let pool = stage?.dsaPagePool {
            let capacity = pool.capacityBytes
            let cap = (try? Self.pagedRetainBytes(ProcessInfo.processInfo.environment)) ?? Self.defaultPagedRetainBytes
            if Self.trimsIdleSlabs(capacityBytes: capacity, retainBytes: cap, underPressure: underPressure) {
                let trimmed = (try? pool.trim()) ?? 0
                slabs = " slabs=trimmed trimmed_bytes=\(trimmed) retained_bytes=\(pool.capacityBytes)"
            } else {
                pool.recycle()
                slabs = " slabs=retained retained_bytes=\(capacity)"
            }
            slabs += " retain_cap_bytes=\(cap)"
        }
        ClusterIdleMemory.releaseFreedBuffers()
        let released = max(0, held - Memory.activeMemory - Memory.cacheMemory)
        // Keep-warm pulses leave a few bytes in the cache between ticks; the
        // slab decision is logged on every idle release that is not a pressure tick.
        if released >= 1 << 20 || (!slabs.isEmpty && !underPressure) {
            log("darkbloom-idle-release-v1 rank=\(collective.rank) released_bytes=\(released) freed_buffer_bytes=\(cached)"
                + " prefix_entries_dropped=\(underPressure ? entries : 0) prefix_bytes_dropped=\(dropped)"
                + " prefix_entries=\(prefix.count) prefix_bytes=\(prefix.bytesInUse) pressure=\(underPressure ? 1 : 0)"
                + " active_bytes=\(Memory.activeMemory)" + slabs)
        }
        return released
    }

    /// The longest context this idle rank's gate admits now, re-derived on
    /// each keep-warm answer (`ClusterWorkerEvent.keptWarm`): prompt-prefix
    /// entries and freed buffers count as free, since a reservation releases
    /// them before it is refused. Nil while a request or lane is held.
    public func refreshServingContext() -> Int? {
        guard operation.try() else { return nil }
        defer { operation.unlock() }
        guard control.available, reservation == nil, laneBook.isEmpty, stage != nil else { return nil }
        // The page slabs' free capacity is kept for the next request and given back before a refusal.
        let retained = stage?.dsaPagePool?.unallocatedBytes ?? 0
        guard let value = try? requestCharge.servingContextTokens(
            reclaimableBytes: prefix.bytesInUse + Memory.cacheMemory + retained) else { return nil }
        if value != servingContextTokens {
            log("darkbloom-serving-context-v1 rank=\(collective.rank) tokens=\(value) previous=\(servingContextTokens ?? 0)"
                + " reclaimable=\(prefix.bytesInUse + Memory.cacheMemory + retained)")
        }
        servingContextTokens = value
        return value
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
        let media = try reservedMedia(value)
        // Charged at its own context (and its media): the live gate alone decides whether it fits.
        let charge = try QwenLongPrefillCheckedBytes.sum([try requestCharge.bytes(contextTokens: request.maximumTokens),
            media?.requestBytes ?? 0])
        try control.check(); try control.reserve(requestID)
        return try control.reserving(requestID, rank: collective.rank, deadline: value.deadlineUptimeNanoseconds) {
            guard stage != nil else { throw ProbeError("Resident model already released") }
            guard charge <= value.capacityLimitBytes else {
                throw ProbeError("GLM tensor-parallel reservation exceeds its owner or readiness capacity")
            }
            // What an idle rank keeps for the next request gives way first.
            // A paged rank also needs what its page pool grows by for this request.
            try yieldingIdleMemory {
                try Self.requireLiveMemory(bytes: try QwenLongPrefillCheckedBytes.sum([charge,
                    pagedGrowthBytes(request)]))
            }
            try control.check(deadline: value.deadlineUptimeNanoseconds)
            reservation = .init(request: request, deadline: value.deadlineUptimeNanoseconds, media: media?.media)
            // Rank 0 prepares the patches off the executor; the request's
            // open waits for them (`GLM5NextTensorParallelMedia.open`).
            if collective.rank == 0 { media?.media.startPreparation() }
            return charge
        }
    }

    /// A reservation's media on this rank, checked against its prompt and
    /// the loaded model, with the bytes it adds to this rank's charge. Rank 0
    /// alone carries the encoded bytes.
    func reservedMedia(_ value: ClusterWorkerReservation) throws
        -> (media: GLM5NextTensorParallelMedia, requestBytes: Int)? {
        guard let described = value.glmMedia else { return nil }
        guard described.carriesEncodedBytes == (collective.rank == 0) else {
            throw ProbeError("GLM media bytes belong to rank 0 alone")
        }
        let media = try GLM5NextTensorParallelMedia(media: described, prompt: value.promptTokenIDs,
            configuration: descriptor.configuration)
        return (media, try GLM5NextTensorParallelMedia.requestBytes(described, rank: collective.rank,
            configuration: descriptor.configuration))
    }

    public func releaseReservation(requestID: UUID) throws {
        guard operation.try() else { throw ProbeError("Resident native operation is already active") }
        defer { operation.unlock() }
        guard let reserved = reservation, reserved.request.requestID == requestID, control.withdraw(requestID) else {
            throw ProbeError("Resident release has no matching unstarted reservation")
        }
        reserved.media?.cancelPreparation()
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
                    weak var releasedVision: GLM5NextStageVision?
                    released = stage; releasedMTP = mtp; releasedVision = vision
                    reservation?.media?.cancelPreparation()
                    for lane in laneBook.reservations() { lane.media?.cancelPreparation() }
                    reservation = nil; laneBook.clear(); stage = nil; mtp = nil; vision = nil
                    guard released == nil, releasedMTP == nil, releasedVision == nil else {
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
        /// The request's page reservation (nil with contiguous histories); it
        /// ends with the request's state.
        let pages: GLM5NextPageReservation?
        /// Prompt tokens restored from the prefix cache.
        let start: Int
        let speculation: GLM5NextTensorParallelSpeculation?
        let chunk: Int
        let keepAt: Int
        /// The request's images and video, their features agreed; nil for text.
        let media: GLM5NextTensorParallelMedia?
        /// A rank stopped (cancel or deadline) before the features were made:
        /// both ranks know, and the request ends without a prefill frame.
        let stopped: Bool
    }

    /// Opens `request` (collective: a digest agreement and, with the prefix
    /// cache on and a prompt longer than a chunk, one prefix vote). A media
    /// request's digest covers its media, its features cross before anything
    /// else (`GLM5NextTensorParallelMedia.open`, which reads `stop` between
    /// its sums) and it neither restores nor keeps prompt prefixes (the
    /// product's media requests are prefix-cache-excluded too).
    func openRequest(_ request: QwenLayerStageGenerationRequest, stage: GLM5NextTextStage,
                     media: GLM5NextTensorParallelMedia? = nil, stop: () -> Bool = { false }) throws -> OpenedRequest {
        let rank = collective.rank
        guard try group.digestsEqual(QwenTensorParallelResidentRuntime.digest64(request.fingerprint + "|" + loadAgreement
            + (media.map { "|glm-media=" + $0.media.fingerprint } ?? ""))) else {
            throw ProbeError("GLM tensor-parallel ranks were given different requests")
        }
        // Rank 0's features reach rank 1 before the prefill: one sealed sum per frame.
        if let media, try !media.open(rank: rank, tower: vision?.tower, sum: { [group] in group.allSum($0) }, stop: stop) {
            return OpenedRequest(cache: stage.newCache(), pages: nil, start: 0, speculation: nil,
                chunk: Self.prefillChunk(requestChunk: request.chunkSize), keepAt: 0, media: media, stopped: true)
        }
        let chunk = Self.prefillChunk(requestChunk: request.chunkSize)
        let prompt = request.promptTokenIDs
        let pages = try reservePages(request)
        // Every request decodes speculatively, greedy or sampled (bias and
        // penalties too: `QwenStageTokenSampler.verifyRound`). Every request
        // primes the NextN history over its prompt (cheap: no attention, MoE
        // or readout), so every prefix entry carries the history at its
        // boundary. Every history grows at most to the request's own length,
        // the length its reservation was charged (`GLM5NextTensorParallelRequestCharge`).
        let historyTokens = requestCharge.historyTokens(contextTokens: request.maximumTokens)
        let speculation = try mtp.map {
            try GLM5NextTensorParallelSpeculation(mtp: $0, depth: Self.mtpDepth, rank: rank, ranks: collective.size,
                primeRows: descriptor.profile.maximumChunkTokens, historyTokens: historyTokens,
                pagePool: pages?.pool, pageAccount: pages?.account,
                agree: { [group] in group.allSum($0) })
        }
        // Prompt prefix: the longest chunk boundary both ranks hold.
        let scope = loadAgreement
        var cache = stage.newCache(account: pages?.account), start = 0
        if prefix.enabled, media == nil, prompt.count > chunk {
            let candidates = QwenTensorParallelPrefixCache.candidates(promptCount: prompt.count, chunk: chunk)
            let held = prefix.heldBoundaries(scope: scope, prompt: prompt, chunk: chunk)
            if let agreed = try QwenTensorParallelPrefixCache.agree(held: held, group: group, candidates: candidates) {
                guard let restored = prefix.restore(scope: scope, prompt: prompt, length: agreed) else {
                    throw ProbeError("GLM tensor-parallel prefix both ranks voted for is gone")
                }
                cache = restored.cache; start = agreed
                // The entry's pages are shared; what the request appends is its own.
                cache.bindPages(to: pages?.account)
                try speculation?.restore(restored.mtp)
            }
        }
        Self.boundHistories(cache, tokens: historyTokens)
        return OpenedRequest(cache: cache, pages: pages, start: start, speculation: speculation, chunk: chunk,
            keepAt: Self.prefixKeepAt(promptCount: prompt.count, chunk: chunk, prefixEnabled: prefix.enabled && media == nil),
            media: media, stopped: false)
    }

    /// One prefill frame `offset ..< end` of `prompt` (`prefillFrameEnd`): its
    /// chunks' micro-batches in one stage forward, the NextN priming in its
    /// evaluation, and the prompt prefix kept when a chunk ends at `keepAt`
    /// (inside the frame or at its end). `merging`: the frame is a merging
    /// one (`prefillFrameEnd(merging: true)`), whose chunks may share
    /// micro-batches. The final frame returns the last row's logits and
    /// hidden row; `stored` is the kept boundary. A media request's frame
    /// runs from its input embeddings, media rows replaced by their features
    /// (`GLM5NextTensorParallelMedia.embeddings`), through the same segments
    /// and micro-batches, and primes the NextN history with the same rows;
    /// a frame without media rows is the text path's.
    func runPrefillFrame(_ prompt: [Int], offset: Int, end: Int, opened: OpenedRequest, stage: GLM5NextTextStage,
                         merging: Bool = true)
        throws -> (final: (logits: MLXArray, lastHidden: MLXArray)?, stored: Int?) {
        guard !opened.stopped else { throw ProbeError("GLM tensor-parallel request stopped before its media crossed") }
        let frame = try GLM5NextTensorParallelPrefillPlan.frame(start: offset, end: end, promptCount: prompt.count,
            chunkTokens: opened.chunk, keepAt: opened.keepAt,
            bulkTokens: Self.bulkPrefillChunkTokens, microBatches: Self.prefillMicroBatches,
            microBatchTokens: Self.prefillMicroBatchTokens, coalescing: merging)
        let result = try GLM5NextTensorParallelPrefillPlan.run(frame, stage: stage, cache: opened.cache, prompt: prompt,
            speculation: opened.speculation, inputs: try Self.mediaInputs(prompt, opened: opened, stage: stage))
        if let kept = result.kept {
            prefix.store(scope: loadAgreement, prompt: prompt, length: kept.end, cache: kept.cache, mtp: kept.history)
        }
        return (result.final, result.kept?.end)
    }

    /// A media request's input embeddings by prompt positions
    /// (`GLM5NextTensorParallelMedia.embeddings`); nil for text.
    static func mediaInputs(_ prompt: [Int], opened: OpenedRequest, stage: GLM5NextTextStage)
        throws -> GLM5NextTensorParallelPrefillPlan.Inputs? {
        guard let media = opened.media else { return nil }
        guard let embedding = stage.embedding else {
            throw ProbeError("GLM tensor-parallel media needs the stage's embedding")
        }
        return { lower, upper in
            try media.embeddings(tokens: MLXArray(prompt[lower ..< upper].map(Int32.init), [1, upper - lower]),
                from: lower, to: upper, embedding: { embedding($0) })
        }
    }

    /// A lane's frame `offset ..< end` begun in layer slices (`runPrefillFrame`'s
    /// frame, `merging` as there; a media request's frames from their input
    /// embeddings, as there).
    func beginPrefillFrame(_ prompt: [Int], offset: Int, end: Int, opened: OpenedRequest, stage: GLM5NextTextStage,
                           merging: Bool) throws -> GLM5NextTensorParallelPrefillPlan.Slices {
        guard !opened.stopped else { throw ProbeError("GLM tensor-parallel request stopped before its media crossed") }
        let frame = try GLM5NextTensorParallelPrefillPlan.frame(start: offset, end: end, promptCount: prompt.count,
            chunkTokens: opened.chunk, keepAt: opened.keepAt,
            bulkTokens: Self.bulkPrefillChunkTokens, microBatches: Self.prefillMicroBatches,
            microBatchTokens: Self.prefillMicroBatchTokens, coalescing: merging)
        return try .init(frame, stage: stage, cache: opened.cache, prompt: prompt, speculation: opened.speculation,
            inputs: try Self.mediaInputs(prompt, opened: opened, stage: stage))
    }

    /// The last slice of a lane's frame: `runPrefillFrame`'s results.
    func finishPrefillFrame(_ slices: GLM5NextTensorParallelPrefillPlan.Slices, prompt: [Int])
        throws -> (final: (logits: MLXArray, lastHidden: MLXArray)?, stored: Int?) {
        let result = try slices.finish()
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
    /// window column, at output indexes from the sampler's committed count
    /// (`QwenStageTokenSampler.verifyRound`: with bias or penalties, the step
    /// path replayed over the round's proposals). Rank 1 puts the window's
    /// argmax, which the agreement ignores: its slot must depend on the
    /// window's logits, or the round's one evaluation may run the agreement
    /// sum before the layer sums on rank 1 only, and the ranks' sums no longer
    /// pair up. Nil for greedy requests (the argmax).
    func verificationDraw(_ sampler: QwenStageTokenSampler?) -> ((MLXArray) -> MLXArray)? {
        let rank = collective.rank
        return sampler.map { sampler in
            { logits in (rank == 0 ? sampler.verifyRound(logits) : argMax(logits, axis: -1)).asType(.float32) }
        }
    }

    /// Sampled MTP rounds: every rank draws proposal j with the request's
    /// sampler and the keyed noise of window column j's output index
    /// (coupled drafting, `coupledDraftSharpness`), so the ranks' proposals
    /// stay equal and a draft close to the target proposes the target's own
    /// draw. Holds no collective: the proposals feed the window on every rank
    /// before its sums. Nil for greedy requests (the argmax).
    func proposalSelection(_ sampler: QwenStageTokenSampler?) -> GLM5NextMTP.ProposalSelection? {
        sampler.map { sampler in
            { logits, step in sampler.propose(logits, step: step, sharpness: Self.coupledDraftSharpness) }
        }
    }

    /// The request asks for each token's logprobs. It decodes in MTP rounds
    /// like every request (owner: MTP always on; the product instead makes
    /// logprob rows MTP-ineligible, `EngineLoopV2.mtpBasicEligible`). Rank 0
    /// gathers them with the product's gather after each token is agreed: a
    /// step's from its row (`QwenStageTokenSampler.takePendingLogprobs`), a
    /// round's from the verify window row whose draw each token is
    /// (`takeRoundLogprobs`). No collective: the logits are already evaluated.
    static func capturesLogprobs(_ sampler: QwenStageTokenSampler?) -> Bool {
        sampler?.wire.capturedLogprobs != nil
    }

    /// A request's MTP counts for its `requestTelemetry` (rank 0): rounds,
    /// proposals and accepted proposals; nil without a NextN layer.
    static func speculationTelemetry(_ speculation: GLM5NextTensorParallelSpeculation?) -> ClusterWorkerRequestTelemetry? {
        speculation.map { .init(mtpDrafted: $0.proposedTokens, mtpAccepted: $0.acceptedTokens, mtpRounds: $0.rounds) }
    }

    /// Rank 0's draft probe for a stateless sampled request (`probesDraftRules`).
    func installDraftProbe(_ speculation: GLM5NextTensorParallelSpeculation, sampler: QwenStageTokenSampler?) {
        guard collective.rank == 0, Self.probesDraftRules, let sampler, sampler.admitsSpeculativeVerification else {
            return
        }
        speculation.draftProbe = Self.draftProbe(sampler)
    }

    // MARK: - One request

    private func generate(_ reserved: Reserved, channel: ClusterCommittedTokenChannel) throws
        -> QwenResidentGenerationCompletion {
        guard let stage else { throw ProbeError("Resident model already released") }
        let request = reserved.request, rank = collective.rank
        let opened = try openRequest(request, stage: stage, media: reserved.media,
            stop: { [control] in (try? control.check(deadline: reserved.deadline)) == nil })
        // Both ranks know a rank stopped before the features crossed: both end
        // here (a stopped request ends the owner's request, as text's does).
        if opened.stopped {
            try control.check(deadline: reserved.deadline)
            throw ProbeError("The peer rank stopped the GLM tensor-parallel media request")
        }
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
        // Rank 0, a logprob request: the agreed tokens' logprobs not yet
        // published, in order (a step's or a round's, `capturesLogprobs`).
        var logprobQueue: [ClusterWorkerTokenLogprobs] = [], logprobNext = 0
        let logs = rank == 0 && Self.capturesLogprobs(sampler)
        /// After a step's token was agreed: the gather its draw made.
        func keepStepLogprobs() throws {
            guard logs else { return }
            guard let drawn = sampler?.takePendingLogprobs() else {
                throw ProbeError("GLM tensor-parallel token has no logprobs")
            }
            logprobQueue.append(drawn)
        }
        /// Commits one agreed token on this rank (and publishes it on rank 0);
        /// the request's own end (EOS or length) at it, else nil.
        func commit(_ value: Int) throws -> ClusterWorkerFinishReason? {
            tokens.append(value)
            if rank == 0 {
                var logprobs: ClusterWorkerTokenLogprobs?
                if logs {
                    guard logprobNext < logprobQueue.count else {
                        throw ProbeError("GLM tensor-parallel token has no logprobs")
                    }
                    logprobs = logprobQueue[logprobNext]; logprobNext += 1
                    if logprobNext == logprobQueue.count { logprobQueue.removeAll(); logprobNext = 0 }
                }
                try channel.publishToken(tokens.count - 1, value, prompt.count + tokens.count - 1, logprobs)
                unanswered = true
            }
            switch QwenTensorParallelStopRule.outcome(isStopToken: request.stopTokenIDs.contains(value),
                                                      committed: tokens.count, outputCount: request.outputCount, wanted: true) {
            case .eos: return .eos
            case .length: return .length
            case .clientStop, .proceed: return nil
            }
        }
        if let speculation, let lastHidden {
            // The first token is agreed as a plain step's; then each round
            // commits 1 to `mtpDepth + 1` agreed tokens. What a round builds
            // and when the loop ends follow from agreed tokens only, so both
            // ranks submit the same sums. A round's tokens are committed
            // while the next round runs (`whileRunning`), unless they end the
            // request. A rank that stopped (client stop, cancel, deadline,
            // memory) stops committing, still ends where the other rank
            // would, and carries its flag in the next round it submits.
            let first = try token(choose(firstLogits, stop: 0).asArray(Float.self))
            try keepStepLogprobs()
            sampler?.commit(first)
            // Sampled: coupled proposals on every rank (`proposalSelection`);
            // rank 0 draws the keyed target sample at every window column, at
            // output indexes from the sampler's committed count (rank 1's slot
            // depends on the logits: `verificationDraw`).
            let draw = verificationDraw(sampler), propose = proposalSelection(sampler)
            installDraftProbe(speculation, sampler: sampler)
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
                    propose: propose, whileRunning: {
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
                if logs {
                    let gathered = sampler?.takeRoundLogprobs(tokens: fresh) ?? []
                    guard gathered.count == fresh.count else { throw ProbeError("GLM tensor-parallel round has no logprobs") }
                    logprobQueue += gathered
                }
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
                    try keepStepLogprobs()
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
            + " mtp_proposed=\(speculation?.proposedTokens ?? 0)" + Self.proposalFields(speculation, sampler: sampler)
            + " media_frames=\(opened.media?.media.frames.count ?? 0) media_tokens=\(opened.media?.featureCount ?? 0)")
        var completion = QwenResidentGenerationCompletion(requestID: request.requestID, finishReason: finish,
            selectedTokenIDs: tokens, completedFrames: tokens.count, committedTokens: prompt.count + tokens.count,
            tokenChainSHA256: sha256(try canonicalJSONData(tokens.map { String($0) })), bothRequestStatesRetired: true,
            reusedPromptTokens: start, storedPromptFrontiers: stored)
        if rank == 0 { completion.telemetry = Self.speculationTelemetry(speculation) }
        return completion
    }
}
