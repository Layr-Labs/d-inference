import DarkbloomClusterProtocol
import DarkbloomClusterSecurity
import Foundation
import MLX
import MLXNN
import MLXLLM

/// Synchronous, process-local native owner of one rank of a resident MiMo
/// pair, for the worker's private executor. It has the dense resident
/// runtime's contract: only cancel and readiness may run on the control
/// thread; concurrent reserve, start and shutdown refuse instead of
/// overlapping MLX work; a hard enclosing process deadline is required because
/// cooperative checks cannot interrupt a blocked native collective; on any
/// throw the caller withdraws this worker and fences its peer out of band.
/// `shutdown` releases only this process's weights.
public final class MiMoResidentRuntime {
    /// Qualification only, `off`: run without the stage's standing residency,
    /// to measure what it buys. Refused unless the process was started with
    /// the explicit qualification flag; both ranks must agree on it.
    public static let residencyEnvironmentName = ClusterStageResidency.environmentName
    /// Qualification only, `on`: rank 1 writes one `darkbloom-mimo-step-v1`
    /// line per selected token (the residual's and the row's digests and the
    /// row's highest candidates). It changes no arithmetic and no decision, so
    /// it is not part of the load agreement. Refused without the explicit
    /// qualification flag.
    public static let stepEvidenceEnvironmentName = "DARKBLOOM_CLUSTER_MIMO_STEP_EVIDENCE"

    let admission: MiMoResidentAdmission
    let control: QwenResidentControl
    let collective: Collective
    let baseReady: ClusterWorkerReady
    /// Declared at load and bound into the load agreement with the peer.
    public let generationMode: QwenResidentGenerationMode
    /// This rank's prompt-prefix cache (on by default; `DARKBLOOM_CLUSTER_PREFIX_CACHE=off`
    /// for diagnosis) and, when its owner configured one, its SSD tier.
    public let prefixCache: QwenStagePrefixCache
    private let operation = NSLock()
    private let keepWarm = ClusterKeepWarm()
    private let lifecycle: QwenLayerStageResidentLifecycle
    private var stage: LoadedMiMoLayerStage?
    private weak var model: Module?
    /// A phase split's decoding rank (rank 1) also holds the producer stage,
    /// so that it can adopt rank 0's state and decode alone, or serve a
    /// request alone. Nil on every other rank and mode.
    private var producer: LoadedMiMoLayerStage?
    private weak var producerModel: Module?
    private var residency: ClusterStageResidency?
    private var reservation: Reservation?
    private var processLeaseOwned = true
    private var recordsSteps = false
    /// `pipeline_mtp_v1`: the agreed terms, and on rank 1 the loaded head.
    private var speculative: MiMoSpeculativeDecode?
    /// A qualification run's hand-off fault (`MiMoQualificationFault`); nil in every installed worker.
    private var handoffFault: QwenPhaseSplitFault?

    private struct Reservation {
        let request: QwenLayerStageGenerationRequest
        let allowance: MiMoResidentRequestAllowance
        let deadline: UInt64
        /// What this request's prefix capture may add (0: it captures nothing).
        var prefixCaptureBytes = 0
    }

    private init(admission: MiMoResidentAdmission, control: QwenResidentControl, collective: Collective,
                 stage: LoadedMiMoLayerStage, producer: LoadedMiMoLayerStage?, residency: ClusterStageResidency?, capacity: Int,
                 lifecycle: QwenLayerStageResidentLifecycle, generationMode: QwenResidentGenerationMode,
                 prefixCache: QwenStagePrefixCache, linkProbe: ClusterWorkerLinkProbe? = nil) {
        self.admission = admission; self.control = control; self.collective = collective
        self.stage = stage; model = stage.model; self.residency = residency; self.lifecycle = lifecycle
        self.producer = producer; producerModel = producer?.model
        self.generationMode = generationMode; self.prefixCache = prefixCache
        baseReady = .init(identity: admission.configuration.identity, rank: collective.rank,
            profile: admission.wireProfile, executionPlanSHA256: admission.plan.fingerprint,
            requestCapacityBytes: capacity, dataPlane: collective.workerDataPlane, linkProbe: linkProbe)
    }

    /// Keep-warm tier 1: one asynchronous pulse on a dedicated stream of this
    /// executor while idle (`ClusterKeepWarm.pulse`); returns its submission
    /// time in nanoseconds. Refuses while a native operation or request runs.
    public func keepWarmPulse() throws -> UInt64 {
        guard operation.try() else { throw ProbeError("Resident native operation is already active") }
        defer { operation.unlock() }
        guard control.available else { throw ProbeError("Keep-warm needs an idle resident owner") }
        return keepWarm.pulse()
    }

    /// Keep-warm tier 2: one 1x16 exchange with the peer on the data plane
    /// while idle (`ClusterKeepWarm.dataPlanePing`); returns its duration in
    /// nanoseconds. Both ranks must be told by their owner; never during a
    /// request.
    public func dataPlanePing() throws -> UInt64 {
        guard operation.try() else { throw ProbeError("Resident native operation is already active") }
        defer { operation.unlock() }
        guard control.available else { throw ProbeError("Keep-warm needs an idle resident owner") }
        return try ClusterKeepWarm.dataPlanePing(collective: collective, check: { try control.check() })
    }

    public var readiness: ClusterWorkerReady? {
        guard control.available, (try? control.check()) != nil else { return nil }
        return baseReady
    }

    /// `generationMode` is the caller's declaration (the worker's
    /// `--generation-mode`); both ranks must be given the same one, and it
    /// must be in the registered model's row. `qualification` says whether
    /// this process may honour the qualification switches in its environment.
    /// `prefixSSDKey`: the 32-byte key of this rank's prompt-prefix SSD tier,
    /// as the worker received it on its input (never from the environment);
    /// nil leaves the tier off (`QwenStagePrefixDiskConfiguration`).
    /// `speculativeDepth` (`pipeline_mtp_v1` only): the head's fixed draft
    /// depth, 1...3; nil means `MiMoMTPTerms.standard` (depth 2). Both ranks must
    /// be given the same.
    public static func load(_ configuration: QwenResidentLoadConfiguration,
                            generationMode mode: QwenResidentGenerationMode = .pipeline,
                            speculativeDepth: Int? = nil,
                            qualification: QwenResidentQualificationSwitches = .refused,
                            dataPlane credential: ClusterDataPlaneCredential? = nil,
                            prefixSSDKey: Data? = nil) throws -> MiMoResidentRuntime {
        let environment = ProcessInfo.processInfo.environment
        try qualification.admit(environment: environment)
        // Image opt-in authorizes this candidate, never the broader experiment
        // that waives an admissible-memory refusal. Check before shared enable,
        // transport setup, checkpoint reads, model construction or GPU work.
        if configuration.runtimeProfile == ClusterMiMoImageCandidate.profileID {
            guard qualification.permitted, !mode.isPhaseSplit, credential != nil else {
                throw ProbeError("MiMo image candidate requires explicit qualification, a keyed data plane and the common two-rank pipeline schedule")
            }
        }
        let memoryMeasurementMode = try MiMoResidentAdmission.memoryMeasurementMode(
            runtimeProfile: configuration.runtimeProfile, environment: environment,
            existingModeWaivesRefusals: QwenDenseStageLoadMeasurement.shared.waivesRefusals)
        // A keyed data plane (S16); its qualification fault only with the switches.
        let tamper = qualification.permitted ? try CollectiveRecordTamper.admit(environment: environment) : nil
        guard tamper == nil || credential != nil else {
            throw ProbeError("\(CollectiveRecordTamper.environmentName) needs a keyed data plane")
        }
        let rekey = qualification.permitted ? try CollectiveRecordRekeyOverride.admit(environment: environment) : nil
        guard rekey == nil || credential != nil else {
            throw ProbeError("\(CollectiveRecordRekeyOverride.environmentName) needs a keyed data plane")
        }
        var transport = ClusterTransport.jaccl
        var keepsResidency = true
        var recordsSteps = false
        if qualification.permitted {
            transport = try ClusterTransport.admit(environment: environment)
            if let memoryMeasurementMode {
                try QwenDenseStageLoadMeasurement.shared.enable(memoryMeasurementMode, permittedBy: qualification)
            }
            if let value = environment[residencyEnvironmentName] {
                guard value == "off" else { throw ProbeError("\(residencyEnvironmentName) takes only the value off") }
                keepsResidency = false
            }
            if let value = environment[stepEvidenceEnvironmentName] {
                guard value == "on" else { throw ProbeError("\(stepEvidenceEnvironmentName) takes only the value on") }
                recordsSteps = true
            }
        } else if let name = [residencyEnvironmentName, stepEvidenceEnvironmentName].first(where: { environment[$0] != nil }) {
            throw ProbeError("\(name) is a qualification switch and this process was not started with "
                + "\(QwenResidentQualificationSwitches.permittingArgument) yes; it is refused, not ignored")
        }
        let handoffFault = try MiMoQualificationFault.admit(environment: environment, qualification: qualification, mode: mode)
        // Recording alone changes no decision, so it is not part of what the ranks agree.
        let measuredGate = QwenDenseStageLoadMeasurement.shared.waivesRefusals
        let directory = configuration.modelDirectory
        func read(_ url: URL, _ limit: Int) throws -> Data { try BoundedProbeInput.data(url, maximumBytes: limit) }
        let admission = try MiMoResidentAdmission(configuration: configuration,
            configBytes: read(directory.appendingPathComponent("config.json"), 1_048_576),
            manifestBytes: read(directory.appendingPathComponent("manifest.json"), 4_194_304),
            environment: environment, now: DispatchTime.now().uptimeNanoseconds, read: read)
        guard admission.specification.supportedGenerationModes.contains(mode) else {
            throw ProbeError("Generation mode \(mode.rawValue) is not in the resident row of "
                + admission.specification.model.rawValue)
        }
        let speculativeTerms: MiMoMTPTerms?
        if mode.usesSpeculativeHead {
            speculativeTerms = try speculativeDepth.map { try MiMoMTPTerms(depth: $0) } ?? .standard
        } else {
            guard speculativeDepth == nil else { throw ProbeError("A speculative depth needs \(ClusterGenerationMode.pipelineMTP.rawValue)") }
            speculativeTerms = nil
        }
        let control = QwenResidentControl(deadline: configuration.deadlineUptimeNanoseconds, lease: configuration.lease)
        try QwenResidentProcessLease.shared.acquire()
        var stage: LoadedMiMoLayerStage?
        var head: MiMoMTPHead?
        var headInventorySHA256: String?
        var producer: LoadedMiMoLayerStage?
        var residency: ClusterStageResidency?
        weak var retired: Module?
        weak var retiredProducer: Module?
        let holdsProducer = mode.isPhaseSplit && configuration.rank == 1
        // A MiMo phase split (a hand-off mode, off by default) hands over state
        // computed from frame 0 and refuses a restored prefix: no cache under it.
        let prefixCache = mode.isPhaseSplit ? QwenStagePrefixCache(enabled: false)
            : QwenStagePrefixCache.fromEnvironment(environment)
        do {
            try control.check(); try QwenResidentResourceEnvironment.require()
            try admission.jaccl.requireUnchanged(environment: ProcessInfo.processInfo.environment, read: read)
            if configuration.allocatorPolicy == .disableFreedBufferCache {
                try MLX.withError { nativeError in
                    func checked() throws { try nativeError.check(); try control.check(); try nativeError.check() }
                    do {
                        try configuration.allocatorPolicy.configure(setCacheLimit: { Memory.cacheLimit = $0 }, check: checked)
                    } catch { try nativeError.check(); throw error }
                }
            }
            let collective: Collective
            if transport == .localSocketTest {
                collective = try Collective(localSocketRank: configuration.rank,
                    coordinator: admission.jaccl.receipt.coordinator,
                    progressTimeoutMilliseconds: CollectiveLocalSocket.progressMilliseconds(
                        environment: ProcessInfo.processInfo.environment),
                    deadlineUptimeNanoseconds: configuration.deadlineUptimeNanoseconds)
                try admission.jaccl.requireUnchanged(environment: ProcessInfo.processInfo.environment, read: read)
                guard collective.rank == admission.jaccl.rank, collective.size == 2 else {
                    throw ProbeError("Resident local-socket-test initialized a different rank or world size")
                }
            } else {
                collective = try Collective(transport: .jaccl)
                try admission.jaccl.requireUnchanged(environment: ProcessInfo.processInfo.environment, read: read)
                try admission.jaccl.requireInitialized(rank: collective.rank, worldSize: collective.size,
                                                       transport: collective.transport)
            }
            let plainAgreement = try admission.loadAgreementFingerprint(mode: mode, transport: transport,
                residency: keepsResidency, measuredGate: measuredGate, speculative: speculativeTerms)
            // Every load over the cable measures the link as the sharded modes use it (`QwenTensorParallelLinkProbe`),
            // so the planner can choose tensor parallel for this pair; bound here so both ranks measure it.
            let probesLink = transport != .localSocketTest
            let probeFields = probesLink ? [QwenTensorParallelLinkProbe.loadAgreementField] : []
            let loadAgreement = credential == nil
                ? (probeFields.isEmpty ? plainAgreement : sha256(try canonicalJSONData([plainAgreement] + probeFields)))
                : sha256(try canonicalJSONData([plainAgreement] + probeFields + ClusterDataPlaneAgreement.loadAgreementFields))
            if let credential {
                try ClusterDataPlaneAgreement.establish(collective: collective, credential: credential,
                    loadAgreement: loadAgreement, tamper: tamper, rekey: rekey, tensorParallelSeal: probesLink,
                    check: { try control.check() })
            }
            var linkProbe: ClusterWorkerLinkProbe?
            let capacity = try MLX.withError { nativeError in
                func checked() throws { try nativeError.check(); try control.check(); try nativeError.check() }
                do {
                    _ = try requireQwenLongPrefillReadinessDigest(collective: collective,
                        material: { .residentLoadIntent(agreementFingerprint: loadAgreement) },
                        disagreementMessage: "Resident MiMo load membership/source/Plan/mode differs", scope: .session(.loadAgreement, "resident-load-intent"), check: checked)
                    if probesLink {
                        // The link, before any weight is read.
                        linkProbe = try QwenTensorParallelLinkProbe.measure(onPipeline: collective, keyed: credential != nil,
                            loadAgreement: loadAgreement, hiddenSize: admission.profile.hiddenSize,
                            chunkTokens: admission.profile.maximumChunkTokens, check: checked)
                        if let linkProbe { log(QwenTensorParallelLinkProbe.line(linkProbe, rank: collective.rank)) }
                    }
                    let beforeLoad = Memory.snapshot()
                    let started = DispatchTime.now().uptimeNanoseconds
                    var verified = started
                    try autoreleasepool {
                        let source = try prepareMiMoResidentSource(directory: directory,
                            configuration: admission.configBytes, manifest: admission.manifestBytes,
                            specification: admission.specification, plan: admission.plan, check: checked)
                        verified = DispatchTime.now().uptimeNanoseconds
                        stage = try loadMiMoResidentStage(source: source, stageIndex: configuration.rank,
                            check: checked, constructed: { retired = $0 })
                        if speculativeTerms != nil {
                            // Both ranks name the head's tensors; the last rank reads them.
                            headInventorySHA256 = try MiMoMTPHead.inventory(source: source).0.sha256
                            if configuration.rank == 1, let consumer = stage {
                                head = try MiMoMTPHead(source: source, consumer: consumer, check: checked)
                            }
                        }
                        // A phase split's decoding rank loads the producer stage after
                        // its own, gated on what its own left (`MiMoStageLoadGate`).
                        if holdsProducer {
                            producer = try loadMiMoResidentStage(source: source, stageIndex: 0,
                                check: checked, constructed: { retiredProducer = $0 })
                        }
                    }
                    guard let loaded = stage else { throw ProbeError("Resident MiMo loader returned no stage") }
                    // The layers the constructed stage holds are the plan's (oMLX U#3638).
                    let ownStage = admission.plan.stages[collective.rank]
                    log(try LayerStageLoadedRange.verify(model: loaded.model, plannedLayers: ownStage.layers.count,
                        firstGlobalLayer: ownStage.sourceRange.lowerBound, rank: collective.rank,
                        model: admission.specification.model.rawValue))
                    guard (producer != nil) == holdsProducer else { throw ProbeError("Resident MiMo producer stage load differs from its mode") }
                    if let producer {
                        let producerStage = admission.plan.stages[0]
                        guard producer.stageIndex == 0 else { throw ProbeError("Resident MiMo producer is not stage 0") }
                        log(try LayerStageLoadedRange.verify(model: producer.model, plannedLayers: producerStage.layers.count,
                            firstGlobalLayer: producerStage.sourceRange.lowerBound, rank: collective.rank,
                            model: admission.specification.model.rawValue))
                    }
                    let finished = DispatchTime.now().uptimeNanoseconds
                    func speculativeBytes(_ chunk: Int) throws -> Int {
                        guard let head, let speculativeTerms else { return 0 }
                        return try head.requestBytes(chunkSize: chunk, depth: speculativeTerms.depth,
                            bound: QwenResidentResourceEnvironment.allocationBound)
                    }
                    let maximum = try MiMoResidentRequestAllowance.derive(specification: admission.specification,
                        plan: admission.plan, rank: collective.rank,
                        maximumTokens: admission.profile.maximumContextTokens,
                        chunkSize: admission.profile.maximumChunkTokens, phaseSplit: mode.isPhaseSplit,
                        speculativeBytes: try speculativeBytes(admission.profile.maximumChunkTokens),imageCandidate:admission.plan.visionEnabled)
                    try configuration.allocatorPolicy.prepareReady(
                        synchronize: { Stream.gpu.synchronize(); Stream.cpu.synchronize() },
                        snapshot: {
                            let value = Memory.snapshot()
                            return .init(activeBytes: value.activeMemory, cachedBytes: value.cacheMemory,
                                         peakBytes: value.peakMemory)
                        }, clearCache: { Memory.clearCache() }, check: checked)
                    // The gate at load: the largest context this Mac admits now,
                    // with the stage resident. Refused only below the smallest
                    // useful request; each request is gated again when reserved.
                    func allowance(_ context: Int, _ chunk: Int) throws -> MiMoResidentRequestAllowance {
                        try MiMoResidentRequestAllowance.derive(specification: admission.specification,
                            plan: admission.plan, rank: collective.rank, maximumTokens: context, chunkSize: chunk,
                            phaseSplit: mode.isPhaseSplit, speculativeBytes: try speculativeBytes(chunk),imageCandidate:admission.plan.visionEnabled)
                    }
                    guard let admitted = try LayerStageContextGate.admitted(profile: admission.profile, charge: { context, _, chunk in
                        .init(reservedBytes: try allowance(context, chunk).reservedBytes, extraNativeBytes: 0, extraHostBytes: 0)
                    }) else {
                        let minimum = LayerStageContextGate.minimumContextTokens(admission.profile)
                        try allowance(minimum, min(admission.profile.maximumChunkTokens,
                                                   min(admission.profile.maximumPromptTokens, minimum - 1))).requireLive()
                        throw ProbeError("Resident load refused: not even a request of \(minimum) context tokens fits on rank \(collective.rank)")
                    }
                    let atAdmitted = try allowance(admitted.context, min(admission.profile.maximumChunkTokens,
                        min(admission.profile.maximumPromptTokens, admitted.context - 1)))
                    try atAdmitted.requireLive()
                    if prefixCache.enabled {
                        // Half the room beside the largest admitted request, at
                        // most the cache's ceiling (the dense runtime's rule).
                        let room = try ClusterStagePrefixBudget.roomBytes(chargeBytes: atAdmitted.reservedBytes)
                        prefixCache.setBudget(QwenStagePrefixCache.budget(roomBytes: room))
                        log("darkbloom-prefix-v1 rank=\(collective.rank) family=mimo budget_bytes=\(prefixCache.budgetBytes)"
                            + " room_bytes=\(room)")
                    }
                    log("darkbloom-resident-context-v1 rank=\(collective.rank) model=\(admission.specification.model.rawValue)"
                        + " limit=\(admission.profile.maximumContextTokens) admitted=\(admitted.context)"
                        + " charge_at_admitted=\(atAdmitted.reservedBytes)"
                        + " transient_at_admitted=\(atAdmitted.budget.workspaceBytes)")
                    try checked()
                    if keepsResidency {
                        Stream.gpu.synchronize(); Stream.cpu.synchronize(); try checked()
                        residency = try ClusterStageResidency(bytes: try QwenLongPrefillCheckedBytes.sum([
                            loaded.receipt.loadedTensorBytes, loaded.vision?.storageBytes ?? 0, producer?.receipt.loadedTensorBytes ?? 0,
                            maximum.reservedBytes, head.map { $0.receipt.headBytes + $0.receipt.embeddingBytes } ?? 0]))
                        try checked()
                    }
                    let afterLoad = Memory.snapshot()
                    // Sizes and durations only, for whoever launched this worker.
                    let loadFields: [String] = [
                        "darkbloom-mimo-resident-load-v1", "rank=\(collective.rank)", "cut=\(configuration.stageCut)",
                        "mode=\(mode.rawValue)", "loaded_tensor_bytes=\(loaded.receipt.loadedTensorBytes)",
                        "vision_tensor_bytes=\(loaded.vision?.storageBytes ?? 0)",
                        "vision_inventory_sha256=\(loaded.visionCommitmentSHA256 ?? "none")",
                        "producer_tensor_bytes=\(producer?.receipt.loadedTensorBytes ?? 0)",
                        "schedule=\(configuration.prefillSchedule.rawValue)",
                        "active_before=\(beforeLoad.activeMemory)", "active_loaded=\(afterLoad.activeMemory)",
                        "cache_loaded=\(afterLoad.cacheMemory)",
                        "verify_ms=\((verified - started) / 1_000_000)",
                        "load_ms=\((finished - verified) / 1_000_000)",
                        "wired_limit=\(residency?.receipt.appliedBytes ?? 0)",
                        "wired_limit_ceiling=\(residency?.receipt.ceilingBytes ?? 0)",
                        "wired_limit_before=\(residency?.receipt.previousBytes ?? 0)",
                        "gate=\(measuredGate ? "measured" : "enforced")",
                    ]
                    log(loadFields.joined(separator: " "))
                    if let speculativeTerms {
                        let receipt = head?.receipt
                        log(["darkbloom-mimo-speculative-head-v1", "rank=\(collective.rank)", "depth=\(speculativeTerms.depth)",
                             "head_tensors=\(receipt?.headTensors ?? 0)", "head_bytes=\(receipt?.headBytes ?? 0)",
                             "embedding_bytes=\(receipt?.embeddingBytes ?? 0)",
                             "active_added=\(receipt?.activeBytesAdded ?? 0)",
                             "load_ms=\((receipt?.loadNanoseconds ?? 0) / 1_000_000)",
                             "request_bytes_at_chunk=\(maximum.speculativeBytes)",
                             "inventory_sha256=\(headInventorySHA256 ?? "none")"].joined(separator: " "))
                    }
                    let loadedIdentity = sha256(try canonicalJSONData([loadAgreement,
                        loaded.receipt.storageCommitmentSHA256, loaded.receipt.sourceParameterLayoutSHA256]
                        + (headInventorySHA256.map { ["speculative-head=" + $0] } ?? [])))
                    _ = try requireQwenLongPrefillReadinessDigest(collective: collective,
                        material: { .residentLoaded(agreementFingerprint: loadedIdentity) },
                        disagreementMessage: "Resident MiMo peers did not load matching verified stage commitments",
                        scope: .session(.loadedReady, "resident-loaded"), check: checked)
                    try checked()
                    return maximum.reservedBytes
                } catch {
                    try nativeError.check()
                    throw error
                }
            }
            // The SSD tier for this plan and rank, when the owner configured one
            // (directory in the environment, key on the input). Opening it
            // sweeps the directories of other plans under its root on this rank.
            if prefixCache.enabled, let loaded = stage {
                prefixCache.disk = QwenStagePrefixDiskTier.open(
                    configuration: .fromEnvironment(environment, key: prefixSSDKey),
                    planScope: QwenStagePrefixDiskTier.planScope(planFingerprint: admission.plan.fingerprint,
                        artifactAggregateSHA256: loaded.receipt.verifiedAggregateSHA256,
                        storageCommitmentSHA256: loaded.receipt.storageCommitmentSHA256,
                        rankBuildSHA256: admission.configuration.identity.peers.map(\.buildSHA256),
                        generationMode: mode.rawValue, prefillSchedule: configuration.prefillSchedule.rawValue),
                    rank: collective.rank,
                    stagingEpoch: admission.configuration.identity.membershipEpoch.uuidString.lowercased())
            }
            let lifecycle = QwenLayerStageResidentLifecycle()
            try control.loaded()
            let runtime = MiMoResidentRuntime(admission: admission, control: control, collective: collective,
                stage: stage!, producer: producer, residency: residency, capacity: capacity, lifecycle: lifecycle,
                generationMode: mode, prefixCache: prefixCache, linkProbe: linkProbe)
            runtime.recordsSteps = recordsSteps
            runtime.speculative = speculativeTerms.map { MiMoSpeculativeDecode(terms: $0, head: head) }
            runtime.handoffFault = handoffFault
            return runtime
        } catch {
            let primary = error; control.fail()
            do {
                try MLX.withError { nativeError in
                    Stream.gpu.synchronize(); Stream.cpu.synchronize()
                    try residency?.end(); residency = nil
                    head = nil; stage = nil; producer = nil
                    try nativeError.check()
                    (primary as? MiMoStageVisionLoadFailure)?.releaseAfterCheckedDrain()
                    Memory.clearCache()
                }
                guard retired == nil, retiredProducer == nil else {
                    throw ProbeError("Resident MiMo failed-load model remains retained")
                }
            } catch {
                // Process admission stays closed if local retirement is unknown.
                throw ProbeError("Resident MiMo load failed (\(primary)); local cleanup failed (\(error))")
            }
            // A failed native membership is not reused in this process.
            throw primary
        }
    }

    /// Metadata and native resource reservation only; no request state or forward.
    /// Returned bytes are this rank's named allowance, not combined peer memory.
    public func reserve(requestID: UUID, request value: ClusterWorkerReservation) throws -> Int {
        guard operation.try() else { throw ProbeError("Resident native operation is already active") }
        defer { operation.unlock() }
        let request = try admission.request(value, id: requestID, now: DispatchTime.now().uptimeNanoseconds,
                                            decodingRankHoldsEveryLayer: generationMode.isPhaseSplit)
        let imageBudget: MiMoStageImageBudget?
        if let media = request.mimoImages {
            let c = try JSONDecoder().decode(MiMoV26Configuration.self,from:admission.configBytes)
            imageBudget = try MiMoStageImageBudget.derive(media,prompt:request.promptTokenIDs,configuration:c,
                chunkSize:min(request.chunkSize,request.promptCount),rank:collective.rank,
                bound:QwenResidentResourceEnvironment.allocationBound)
            guard collective.rank != 0 || stage?.vision != nil else { throw ProbeError("MiMo image tower is not loaded") }
        } else { imageBudget = nil }
        try control.check(); try control.reserve(requestID)
        // Nothing below allocates: a throw is a refusal of this request alone.
        return try control.reserving(requestID, rank: collective.rank, deadline: value.deadlineUptimeNanoseconds) {
            guard let stage else { throw ProbeError("Resident model already released") }
            let chunk = min(request.chunkSize, request.promptCount)
            var headBytes = 0
            if let speculative, let head = speculative.head {
                headBytes = try head.requestBytes(chunkSize: chunk, depth: speculative.terms.depth,
                    bound: QwenResidentResourceEnvironment.allocationBound)
            }
            var allowance = try MiMoResidentRequestAllowance.derive(specification: admission.specification,
                plan: admission.plan, rank: collective.rank, maximumTokens: request.maximumTokens,
                chunkSize: chunk, phaseSplit: generationMode.isPhaseSplit, speculativeBytes: headBytes,imageCandidate:admission.plan.visionEnabled)
            if let budget = imageBudget {
                // Check the combined sum before storing in the nonthrowing ledger accessor.
                _ = try QwenLongPrefillCheckedBytes.sum([allowance.reservedBytes,budget.reservedBytes])
                allowance.imageBytes = max(allowance.imageBytes,budget.reservedBytes)
                guard collective.rank != 0 || stage.vision != nil else { throw ProbeError("MiMo image tower is not loaded") }
            }
            guard allowance.reservedBytes <= value.capacityLimitBytes,
                  allowance.reservedBytes <= baseReady.requestCapacityBytes else {
                throw ProbeError("Resident reservation exceeds its additional owner capacity ceiling")
            }
            var reserved = Reservation(request: request, allowance: allowance, deadline: value.deadlineUptimeNanoseconds)
            // Only what this request's capture adds after the prefix this rank
            // holds for it (nothing on a repeat of the whole prompt), under the
            // scope its agreement will key the cache by.
            if prefixCache.enabled {
                let scope = qwenStagePrefixScope(source: try Self.sourceIdentity(stage: stage, admission: admission),
                    numericalPolicySHA256: admission.arithmeticSHA256, request: request)
                reserved.prefixCaptureBytes = prefixCache.captureLimit(scope: scope, tokens: request.promptTokenIDs,
                    chunkSize: request.chunkSize)
            }
            // Kept prefixes give way before a reservation is refused for memory,
            // and this request's own capture is optional.
            do {
                try prefixCache.yieldingMemory { try allowance.requireLive(additionalNativeBytes: reserved.prefixCaptureBytes) }
            } catch where reserved.prefixCaptureBytes > 0 {
                log("darkbloom-prefix-v1 rank=\(collective.rank) family=mimo capture-dropped bytes=\(reserved.prefixCaptureBytes): \(error)")
                reserved.prefixCaptureBytes = 0
                try prefixCache.yieldingMemory { try allowance.requireLive() }
            }
            try control.check(deadline: value.deadlineUptimeNanoseconds)
            prefixCache.admitCapture(prefixCache.enabled ? reserved.prefixCaptureBytes : nil)
            reservation = reserved
            return allowance.reservedBytes
        }
    }

    /// Gives back a reservation that never started, when the pair's owner
    /// cancels it because the other rank refused the request.
    public func releaseReservation(requestID: UUID) throws {
        guard operation.try() else { throw ProbeError("Resident native operation is already active") }
        defer { operation.unlock() }
        guard let reserved = reservation, reserved.request.requestID == requestID, control.withdraw(requestID) else {
            throw ProbeError("Resident release has no matching unstarted reservation")
        }
        reservation = nil; prefixCache.admitCapture(nil)
    }

    /// Only rank 0 invokes the callback, after both ranks commit and accept the
    /// token. False requests an agreed clean stop; a thrown callback is failure.
    public func start(requestID: UUID,
                      onCommittedToken: (Int, Int, Int) throws -> Bool) throws -> QwenResidentGenerationCompletion {
        guard operation.try() else { throw ProbeError("Resident native operation is already active") }
        defer { operation.unlock() }
        guard let reserved = reservation, reserved.request.requestID == requestID else {
            throw ProbeError("Resident start has no matching reservation")
        }
        do {
            let value = try QwenResidentRequestPublication.run(control: control, lifecycle: lifecycle,
                identity: .init(requestID: requestID, epoch: requestID,
                    recordedRequestFingerprint: reserved.request.fingerprint), deadline: reserved.deadline, body: {
                try autoreleasepool {
                    guard let stage else { throw ProbeError("Resident model already released") }
                    return try run(stage: stage, producer: producer, reserved: reserved, onCommittedToken: onCommittedToken)
                }
            }, prepare: { $0 })
            reservation = nil
            return value
        } catch {
            // The peer may have stored or dropped differently; a failed owner
            // keeps nothing it cannot prove both ranks hold.
            prefixCache.sweep()
            control.fail(); throw error
        }
    }

    /// The source identity both ranks' generation agreement carries for a
    /// request on this loaded stage.
    private static func sourceIdentity(stage: LoadedMiMoLayerStage, admission: MiMoResidentAdmission) throws
        -> QwenLayerStageWireSourceIdentity {
        let receipt = stage.receipt
        return try QwenLayerStageWireSourceIdentity(sourceConfigurationSHA256: receipt.sourceConfigurationSHA256,
            artifactAggregateSHA256: receipt.verifiedAggregateSHA256,
            storageCommitmentSHA256: stage.storageCommitmentSHA256,
            planFingerprint: admission.plan.fingerprint,
            producerStageFingerprint: admission.plan.stages[0].fingerprint)
    }

    private func run(stage: LoadedMiMoLayerStage, producer: LoadedMiMoLayerStage?, reserved: Reservation,
                     onCommittedToken: (Int, Int, Int) throws -> Bool) throws -> QwenResidentGenerationCompletion {
        guard (generationMode.isPhaseSplit && collective.rank == 1) == (producer != nil) else {
            throw ProbeError("Resident MiMo generation mode differs from its loaded stages")
        }
        // Both ranks derive the hand-off terms from the producer stage they hold
        // and this request; the agreement fingerprint carries them.
        let split = generationMode.isPhaseSplit
            ? try QwenPhaseSplitPlan(mimoProducer: producer ?? stage, request: reserved.request) : nil
        let source = try Self.sourceIdentity(stage: stage, admission: admission)
        let agreement = try QwenLayerStageGenerationAgreement(request: reserved.request,
            membershipEpoch: admission.configuration.identity.membershipEpoch, source: source,
            consumerStageFingerprint: admission.plan.stages[1].fingerprint,
            rankBuildSHA256: admission.configuration.identity.peers.map(\.buildSHA256),
            numericalPolicySHA256: admission.arithmeticSHA256,
            prefillPolicy: QwenResidentPrefillSelection.policy(admission.configuration.prefillSchedule),
            phaseSplit: split, compactDecode: generationMode == .pipelineCompactDecode,
            speculativeRoundsFraming: speculative?.terms.decodeFraming)
        var lastResourceCheck: UInt64 = 0, ordinal = 0
        var captureCharge = reserved.prefixCaptureBytes
        func check() throws {
            try control.check(deadline: reserved.deadline)
            let now = DispatchTime.now().uptimeNanoseconds
            if lastResourceCheck == 0 || now - lastResourceCheck >= 250_000_000 {
                // Kept prefixes give way first, then this request's own capture.
                captureCharge = try QwenResidentRequestExecution.checkRunning(captureBytes: captureCharge,
                    prefixCache: prefixCache, rank: collective.rank,
                    live: { try reserved.allowance.requireLive(additionalNativeBytes: $0) })
                lastResourceCheck = DispatchTime.now().uptimeNanoseconds
            }
            try control.check(deadline: reserved.deadline)
        }
        try check()
        let started = DispatchTime.now().uptimeNanoseconds
        var firstToken: UInt64?
        let (result, evidence) = try runMiMoLayerStageGenerationRequest(loaded: stage, plan: admission.plan,
            agreement: agreement, collective: collective, recordsSteps: recordsSteps, prefixCache: prefixCache,
            speculative: speculative, producerStage: producer,
            handoffFault: agreement.phaseSplit == nil ? nil : handoffFault, onCommittedToken: { token in
                let current = ordinal; ordinal += 1
                if firstToken == nil { firstToken = DispatchTime.now().uptimeNanoseconds }
                return try onCommittedToken(current, token, reserved.request.promptCount + current)
            }, check: check)
        let finished = DispatchTime.now().uptimeNanoseconds
        guard result.bothRequestStatesRetired,
              let reason = ClusterWorkerFinishReason(rawValue: result.finishReason.rawValue) else {
            throw ProbeError("Resident generation returned without clean bilateral retirement")
        }
        // Digests and in-process durations, for whoever launched this worker.
        // The clock is this rank's own; neither figure is a serving latency.
        let peak = Memory.snapshot()
        let firstTokenMilliseconds = firstToken.map { String(($0 - started) / 1_000_000) } ?? "none"
        let requestFields: [String] = [
            "darkbloom-mimo-request-v1", "rank=\(collective.rank)",
            "request=\(reserved.request.requestID.uuidString.lowercased())",
            "prompt_tokens=\(reserved.request.promptCount)", "selected=\(result.selectedTokenIDs.count)",
            "token_chain_sha256=\(result.tokenChainSHA256)",
            "boundary_chain_sha256=\(evidence.boundaryChainSHA256)",
            "last_row_sha256=\(evidence.lastRowSHA256 ?? "none")",
            "ms=\((finished - started) / 1_000_000)", "first_token_ms=\(firstTokenMilliseconds)",
            "active=\(peak.activeMemory)", "peak=\(peak.peakMemory)",
            "prefix_reused=\(result.prefixCache?.reusedPromptTokens ?? 0)",
            "prefix_tier=\(result.prefixCache?.restoredTier ?? "none")",
            "prefix_stored=\((result.prefixCache?.storedFrontiers ?? []).map(String.init).joined(separator: ","))",
        ]
        for step in evidence.steps { log(step.line(rank: collective.rank)) }
        log(requestFields.joined(separator: " "))
        if let statistics = evidence.speculative {
            log((["darkbloom-mimo-speculative-v1", "rank=\(collective.rank)",
                  "request=\(reserved.request.requestID.uuidString.lowercased())"] + statistics.diagnosticFields)
                .joined(separator: " "))
        }
        // S16: the session's record counters and key generations so far.
        collective.logDataPlaneStatus()
        var completion = QwenResidentGenerationCompletion(requestID: reserved.request.requestID, finishReason: reason,
            selectedTokenIDs: result.selectedTokenIDs, completedFrames: result.completedFrames,
            committedTokens: result.committedTokens, tokenChainSHA256: result.tokenChainSHA256,
            bothRequestStatesRetired: true)
        completion.reusedPromptTokens = result.prefixCache?.reusedPromptTokens ?? 0
        completion.storedPromptFrontiers = result.prefixCache?.storedFrontiers ?? []
        return completion
    }

    public func cancel(requestID: UUID) { control.cancel(requestID) }

    /// Local release only. On failure the external owner must retain and fence
    /// its peer and must not manufacture a successful retirement event.
    public func shutdown() throws {
        guard operation.try() else { throw ProbeError("Cannot release a running native request") }
        defer { operation.unlock() }
        try control.beginClose()
        collective.logDataPlaneStatus()
        do {
            try lifecycle.withModelRelease {
                try MLX.withError { error in
                    Stream.gpu.synchronize(); Stream.cpu.synchronize(); try error.check()
                    // Every rank sweeps its cache before its model goes. Records
                    // already queued for the SSD are finished first (bounded):
                    // they are what a restarted pair restores.
                    prefixCache.disk?.close()
                    prefixCache.sweep()
                    try residency?.end(); residency = nil
                    reservation = nil; speculative = nil; stage = nil; producer = nil
                    guard model == nil, producerModel == nil else { throw ProbeError("Resident MiMo model remains retained") }
                    Memory.clearCache(); try error.check()
                    Stream.gpu.synchronize(); Stream.cpu.synchronize(); try error.check()
                    let after = Memory.snapshot()
                    log("darkbloom-mimo-resident-release-v1 rank=\(collective.rank) active=\(after.activeMemory)"
                        + " cache=\(after.cacheMemory) wired_limit=\(ClusterStageResidency.current)")
                }
            }
            control.closed()
            processLeaseOwned = false; QwenResidentProcessLease.shared.release()
        } catch { control.fail(); throw error }
    }

    deinit {
        // Explicit shutdown is required. Do not reopen the process-wide native
        // admission if a caller dropped an owner without acknowledged cleanup.
        if processLeaseOwned { control.fail() }
    }
}
