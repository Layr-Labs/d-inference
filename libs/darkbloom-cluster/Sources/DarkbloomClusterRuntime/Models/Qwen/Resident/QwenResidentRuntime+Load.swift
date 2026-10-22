import DarkbloomClusterProtocol
import DarkbloomClusterSecurity
import Foundation
import MLX
import MLXNN

extension QwenResidentRuntime {
    /// `generationMode` is the caller's declaration (the worker's
    /// `--generation-mode`); nothing is read from the environment for it. Both
    /// ranks must be given the same mode: it is part of the load agreement they
    /// compare before either stage is read, and it must be in the registered
    /// model's own resident row.
    ///
    /// `qualification` says whether this process may honour the two
    /// qualification switches in its environment. The default refuses them: a
    /// switch that is present and not permitted stops the load here, by name.
    ///
    /// `speculativeTerms` applies only to `phase_split_mtp_v1` and
    /// `pipeline_mtp_v1` (default: the row's own depth,
    /// `QwenMTPTerms.standard(for:mode:)`); both ranks bind them into the load
    /// agreement together with the digest of the head's verified files. Under
    /// `pipeline_mtp_v1` rank 1 reads the head and a copy of the token
    /// embedding beside its stage (`QwenEmbeddingCopy`); rank 0 holds no head.
    ///
    /// `dataPlane` (S16): this rank's credential. When present, the two ranks
    /// key their data plane right after the group exists, each verifying the
    /// other's hello against the identity it pins, and every later transfer
    /// (agreements, residuals, hand-off, tokens, relays, prefix plan, keep-warm)
    /// is an authenticated, encrypted record. Nil keeps the plaintext path.
    ///
    /// `prefixSSDKey`: the 32-byte key of this rank's prompt-prefix SSD tier,
    /// as the worker received it on its input (never from the environment).
    /// Nil leaves the tier off; the directory and budgets still come from the
    /// environment (`QwenStagePrefixDiskConfiguration`).
    public static func load(_ configuration: QwenResidentLoadConfiguration,
                            generationMode mode: QwenResidentGenerationMode = .pipeline,
                            speculativeTerms requestedTerms: QwenMTPTerms? = nil,
                            qualification: QwenResidentQualificationSwitches = .refused,
                            dataPlane credential: ClusterDataPlaneCredential? = nil,
                            prefixSSDKey: Data? = nil) throws -> QwenResidentRuntime {
        let launchEnvironment = ProcessInfo.processInfo.environment
        try qualification.admit(environment: launchEnvironment)
        // Graph-shaping terms both ranks bind into the load agreement: the
        // stages' KV storage (paged unless the diagnosis switch names contiguous) and the batch lanes.
        let batch = try QwenBatchSettings.fromEnvironment(launchEnvironment)
        let kvKind = try ClusterStageKVBackendKind.resolved(environment: launchEnvironment,
            speculative: mode.usesSpeculativeHead, batchLanes: batch.lanes)
        // JACCL unless the single-Mac qualification socket was permitted and declared.
        var transport = ClusterTransport.jaccl
        // A recording request may be asked to commit this; fixed here, once.
        var fault: QwenPhaseSplitFault?
        var tamper: CollectiveRecordTamper?
        var rekey: ClusterRecordRekeyPolicy?
        if qualification.permitted {
            transport = try ClusterTransport.admit(environment: launchEnvironment)
            fault = try QwenPhaseSplitFault.admit(environment: launchEnvironment)
            tamper = try CollectiveRecordTamper.admit(environment: launchEnvironment)
            guard tamper == nil || credential != nil else {
                throw ProbeError("\(CollectiveRecordTamper.environmentName) needs a keyed data plane")
            }
            rekey = try CollectiveRecordRekeyOverride.admit(environment: launchEnvironment)
            guard rekey == nil || credential != nil else {
                throw ProbeError("\(CollectiveRecordRekeyOverride.environmentName) needs a keyed data plane")
            }
            // The host memory gate's record or measure mode, the same switch for every adapter.
            if let gate = try QwenDenseStageLoadMeasurement.requested(environment: launchEnvironment) {
                try QwenDenseStageLoadMeasurement.shared.enable(gate, permittedBy: qualification)
            }
        }
        // The owner-authenticated bootstrap, when the worker installed one
        // (`JACCLOwnerBootstrap`), creates the JACCL group in `Collective`.
        let directory = configuration.modelDirectory
        // The identity's model ID selects the registered family that admits it.
        let admission = try LayerStageResidentFamily.admission(configuration: configuration,
            configBytes: BoundedProbeInput.data(directory.appendingPathComponent("config.json"), maximumBytes: 1_048_576),
            manifestBytes: BoundedProbeInput.data(directory.appendingPathComponent("manifest.json"), maximumBytes: 4_194_304),
            environment: ProcessInfo.processInfo.environment, now: DispatchTime.now().uptimeNanoseconds,
            read: { try BoundedProbeInput.data($0, maximumBytes: $1) })
        // The model's own row decides which modes it runs; nothing else does.
        guard admission.supportedGenerationModes.contains(mode) else {
            throw ProbeError("Generation mode \(mode.rawValue) is not in the resident row of \(admission.runtimeModelID)")
        }
        // Tensor parallel has its own resident owner (`QwenTensorParallelResidentRuntime`).
        guard !mode.usesTensorParallelDecode else {
            throw ProbeError("Generation mode \(mode.rawValue) runs on the tensor-parallel resident owner, not the stage runtime")
        }
        guard requestedTerms == nil || mode.usesSpeculativeHead else {
            throw ProbeError("Speculative terms were declared for a mode without a speculative head")
        }
        // The head's files by their verified manifest digests, on both ranks,
        // before either stage is read; only rank 1 loads the head itself.
        let speculativeTerms: QwenMTPTerms?
        if mode.usesSpeculativeHead {
            guard let model = QwenRegisteredDenseModel(rawValue: admission.runtimeModelID) else {
                throw ProbeError("Speculative decoding needs a registered resident row; \(admission.runtimeModelID) is not one")
            }
            speculativeTerms = requestedTerms ?? .standard(for: model, mode: mode)
        } else { speculativeTerms = nil }
        let headFiles: QwenMTPHeadFiles? = mode.usesSpeculativeHead
            ? try QwenMTPHeadFiles(modelDirectory: directory, manifest: admission.manifestBytes) : nil
        let control = QwenResidentControl(deadline: configuration.deadlineUptimeNanoseconds, lease: configuration.lease)
        try QwenResidentProcessLease.shared.acquire()
        var stage: (any LayerStageResidentStage)?
        var producerStage: (any LayerStageResidentStage)?
        var speculativeHead: QwenMTPHead?
        weak var retired: Module?
        weak var retiredProducer: Module?
        do {
            try control.check(); try QwenResidentResourceEnvironment.require()
            try admission.jaccl.requireUnchanged(environment: ProcessInfo.processInfo.environment,
                read: { try BoundedProbeInput.data($0, maximumBytes: $1) })
            // The dedicated worker opts in only after typed and actual gates.
            // Default facade loads never change the process cache setting.
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
                // Both ranks on this Mac, on the admitted coordinator endpoint.
                collective = try Collective(localSocketRank: configuration.rank,
                    coordinator: admission.jaccl.receipt.coordinator,
                    progressTimeoutMilliseconds: CollectiveLocalSocket.progressMilliseconds(
                        environment: ProcessInfo.processInfo.environment),
                    deadlineUptimeNanoseconds: configuration.deadlineUptimeNanoseconds)
                try admission.jaccl.requireUnchanged(environment: ProcessInfo.processInfo.environment,
                    read: { try BoundedProbeInput.data($0, maximumBytes: $1) })
                guard collective.rank == admission.jaccl.rank, collective.size == 2 else {
                    throw ProbeError("Resident local-socket-test initialized a different rank or world size")
                }
            } else {
                collective = try Collective(transport: .jaccl)
                try admission.jaccl.requireUnchanged(environment: ProcessInfo.processInfo.environment,
                    read: { try BoundedProbeInput.data($0, maximumBytes: $1) })
                try admission.jaccl.requireInitialized(rank: collective.rank, worldSize: collective.size, transport: collective.transport)
            }
            // The pipeline keeps its existing agreement bytes. Any other mode is
            // bound here, so a peer that was told something else stops at the
            // first exchange, before either stage is read.
            var common = try admission.loadAgreementFingerprint()
            var speculativeFields: [String] = []
            if let speculativeTerms, let headFiles {
                speculativeFields = speculativeTerms.loadAgreementFields(headSHA256: headFiles.sha256)
            }
            guard !batch.batching || mode == .pipeline else {
                throw ProbeError("Batch lanes serve the pipeline mode only; \(mode.rawValue) keeps one request at a time")
            }
            // Every load over the cable measures the link as the sharded modes use it (`QwenTensorParallelLinkProbe`,
            // the sealed all-sum on a keyed plane), so the planner can choose tensor parallel for this pair next.
            let probesLink = transport != .localSocketTest
            let agreementFields = mode.loadAgreementFields + speculativeFields + transport.loadAgreementFields
                + (credential == nil ? [] : ClusterDataPlaneAgreement.loadAgreementFields)
                + kvKind.loadAgreementFields + batch.loadAgreementFields
                + (probesLink ? [QwenTensorParallelLinkProbe.loadAgreementField] : [])
            if !agreementFields.isEmpty { common = sha256(try canonicalJSONData([common] + agreementFields)) }
            let loadAgreement = common
            if let credential {
                try ClusterDataPlaneAgreement.establish(collective: collective, credential: credential,
                    loadAgreement: loadAgreement, tamper: tamper, rekey: rekey, tensorParallelSeal: probesLink,
                    check: { try control.check() })
            }
            var linkProbe: ClusterWorkerLinkProbe?
            // The context the gate admitted at load and the allocator's active
            // bytes with the model resident: the serving context's first value
            // and its idle baseline (`refreshServingContext`).
            var servingContext: Int?
            var activeLoaded = 0
            var prefixBudget: Int?
            let capacity = try MLX.withError { nativeError in
                func checked() throws { try nativeError.check(); try control.check(); try nativeError.check() }
                do {
                    _ = try requireQwenLongPrefillReadinessDigest(collective: collective,
                        material: { .residentLoadIntent(agreementFingerprint: loadAgreement) },
                        disagreementMessage: "Resident load membership/source/Plan/mode differs", scope: .session(.loadAgreement, "resident-load-intent"), check: checked)
                    if probesLink {
                        // The link, before any weight is read: both ranks agreed above that they measure it.
                        linkProbe = try QwenTensorParallelLinkProbe.measure(onPipeline: collective, keyed: credential != nil,
                            loadAgreement: loadAgreement, hiddenSize: admission.profile.hiddenSize,
                            chunkTokens: admission.profile.maximumChunkTokens, check: checked)
                        if let linkProbe { log(QwenTensorParallelLinkProbe.line(linkProbe, rank: collective.rank)) }
                    }
                    let beforeLoad = Memory.snapshot()
                    // The decoding rank of a phase split loads both stages of one
                    // artifact: it is verified once for both (finding R1).
                    let sharesVerification = mode.isPhaseSplit && collective.rank == 1
                    if sharesVerification { VerifiedCheckpointReuse.begin() }
                    defer { if sharesVerification { VerifiedCheckpointReuse.end() } }
                    var embeddingCopy: QwenEmbeddingCopy?
                    try autoreleasepool {
                        if mode == .pipelineMTP, collective.rank == 1 {
                            // The last rank of a speculative pipeline reads a copy of
                            // the token embedding with its stage, through the same
                            // verified checkpoint, for the head.
                            guard let qwen = admission as? QwenResidentAdmission else {
                                throw ProbeError("Speculative pipeline rounds need a registered Qwen row")
                            }
                            let value = try loadQwenResidentStageWithEmbeddingCopy(qwen, check: checked)
                            retired = value.stage.loaded.model; stage = value.stage; embeddingCopy = value.embedding
                        } else {
                            let value = try admission.loadResidentStage(check: checked, constructed: { _ in })
                            retired = value.loaded.model; stage = value
                        }
                    }
                    guard let loaded = stage else { throw ProbeError("Resident loader returned no stage") }
                    // The layers the constructed stage holds are the plan's (oMLX U#3638).
                    let ownStage = admission.plan.stages[collective.rank]
                    log(try LayerStageLoadedRange.verify(model: loaded.loaded.model, plannedLayers: ownStage.layers.count,
                        firstGlobalLayer: ownStage.sourceRange.lowerBound, rank: collective.rank, model: admission.runtimeModelID))
                    if mode.isPhaseSplit, collective.rank == 1 {
                        // Rank 1 also holds the producer stage, admitted and loaded
                        // exactly as rank 0 loads it, so it owns every layer once
                        // rank 0 hands its request state over. No collective is
                        // created for it; only the rank in the environment differs.
                        var environment = ProcessInfo.processInfo.environment
                        for name in ["JACCL_RANK", "MLX_RANK"] where environment[name] != nil { environment[name] = "0" }
                        let producerAdmission = try LayerStageResidentFamily.admission(configuration: .init(
                                identity: configuration.identity, modelDirectory: configuration.modelDirectory, rank: 0,
                                stageCut: configuration.stageCut,
                                deadlineUptimeNanoseconds: configuration.deadlineUptimeNanoseconds,
                                allocatorPolicy: configuration.allocatorPolicy, prefillSchedule: configuration.prefillSchedule,
                                lease: configuration.lease),
                            configBytes: admission.configBytes, manifestBytes: admission.manifestBytes,
                            environment: environment, now: DispatchTime.now().uptimeNanoseconds,
                            read: { try BoundedProbeInput.data($0, maximumBytes: $1) })
                        guard producerAdmission.plan.fingerprint == admission.plan.fingerprint,
                              producerAdmission.arithmeticSHA256 == admission.arithmeticSHA256,
                              producerAdmission.jaccl.fingerprint == admission.jaccl.fingerprint else {
                            throw ProbeError("Producer stage admission differs from this rank's Plan or arithmetic")
                        }
                        try autoreleasepool {
                            let value = try producerAdmission.loadResidentStage(check: checked, constructed: { _ in })
                            retiredProducer = value.loaded.model; producerStage = value
                        }
                        guard let producer = producerStage,
                              producer.loaded.receipt.storageCommitmentSHA256 == loaded.loaded.receipt.storageCommitmentSHA256,
                              producer.loaded.receipt.verifiedAggregateSHA256 == loaded.loaded.receipt.verifiedAggregateSHA256,
                              producer.loaded.receipt.sourceParameterLayoutSHA256 == loaded.loaded.receipt.sourceParameterLayoutSHA256 else {
                            throw ProbeError("Producer and consumer stages did not load matching verified commitments")
                        }
                        if mode.usesSpeculativeHead {
                            // After both stages: the head borrows the producer's
                            // embedding and the consumer's final norm and output head.
                            let head = try autoreleasepool {
                                try QwenMTPHead(modelDirectory: directory, sourceConfiguration: admission.configBytes,
                                    manifest: admission.manifestBytes, producer: producer.loaded, consumer: loaded.loaded,
                                    check: checked)
                            }
                            guard head.headSHA256 == headFiles?.sha256 else {
                                throw ProbeError("Speculative head files differ from the agreed head")
                            }
                            speculativeHead = head
                            log("darkbloom-speculative-head-v1 rank=1 depth=\(speculativeTerms?.depth ?? 0)"
                                + " files=\(head.receipt.tensorFiles.count) file_bytes=\(head.receipt.tensorFileBytes)"
                                + " active_added=\(head.receipt.activeBytesAdded) load_ns=\(head.receipt.loadNanoseconds)")
                        }
                    }
                    if mode == .pipelineMTP, collective.rank == 1 {
                        // After the stage: the head borrows the embedding copy and the
                        // consumer stage's final norm and output head.
                        guard let copy = embeddingCopy else { throw ProbeError("The embedding copy was not read") }
                        let head = try autoreleasepool {
                            try QwenMTPHead(modelDirectory: directory, sourceConfiguration: admission.configBytes,
                                manifest: admission.manifestBytes, embeddingCopy: copy, consumer: loaded.loaded,
                                check: checked)
                        }
                        embeddingCopy = nil
                        guard head.headSHA256 == headFiles?.sha256 else {
                            throw ProbeError("Speculative head files differ from the agreed head")
                        }
                        speculativeHead = head
                        log("darkbloom-speculative-head-v1 rank=1 mode=\(mode.rawValue) depth=\(speculativeTerms?.depth ?? 0)"
                            + " files=\(head.receipt.tensorFiles.count) file_bytes=\(head.receipt.tensorFileBytes)"
                            + " embedding_copy_bytes=\(head.receipt.embeddingCopyBytes)"
                            + " active_added=\(head.receipt.activeBytesAdded) load_ns=\(head.receipt.loadNanoseconds)")
                    }
                    // Each loaded stage's shared KV storage (Qwen 3.5 stages; other
                    // families keep their per-request contiguous storage).
                    for value in [loaded.loaded] + (producerStage.map { [$0.loaded] } ?? []) {
                        try CBv2StageKVHost.install(on: value, kind: kvKind, lanes: batch.lanes,
                            maximumTokensPerRequest: admission.profile.maximumContextTokens,
                            maximumChunkTokens: admission.profile.maximumChunkTokens)
                    }
                    if batch.batching, loaded.loaded.kvHost.host == nil {
                        throw ProbeError("Batch lanes need a stage KV host; this model's stages keep per-request storage")
                    }
                    let maximum = try loaded.requestAllowance(plan: admission.plan,
                        rank: collective.rank, maximumTokens: admission.profile.maximumContextTokens,
                        chunkSize: admission.profile.maximumChunkTokens, bound: QwenResidentResourceEnvironment.allocationBound)
                    try configuration.allocatorPolicy.prepareReady(
                        synchronize: { Stream.gpu.synchronize(); Stream.cpu.synchronize() },
                        snapshot: {
                            let value = Memory.snapshot()
                            return .init(activeBytes: value.activeMemory, cachedBytes: value.cacheMemory,
                                peakBytes: value.peakMemory)
                        }, clearCache: { Memory.clearCache() }, check: checked)
                    let prefill = try QwenResidentPrefillSelection.allowance(
                        QwenResidentPrefillSelection.policy(configuration.prefillSchedule), rank: collective.rank,
                        promptCount: admission.profile.maximumPromptTokens, chunkSize: admission.profile.maximumChunkTokens,
                        hiddenSize: admission.profile.hiddenSize,
                        elementBytes: qwenStageWireElementBytes(admission.profile.activationDType),
                        bound: QwenResidentResourceEnvironment.allocationBound)
                    let split = try QwenResidentRuntime.phaseSplitAllowance(mode, admission: admission,
                        stage: loaded, rank: collective.rank, promptCount: admission.profile.maximumPromptTokens,
                        speculativeTerms: speculativeTerms)
                    // The gate at load: the largest context this Mac admits now,
                    // with the stage resident. Refused only below the smallest
                    // useful request; each request is gated again when reserved.
                    let admitted = try QwenResidentRuntime.admittedContext(admission: admission, stage: loaded,
                        rank: collective.rank, mode: mode, speculativeTerms: speculativeTerms)
                    try admitted.allowance.requireLive(additionalNativeBytes: admitted.extraNativeBytes,
                        additionalHostBytes: admitted.extraHostBytes)
                    servingContext = admitted.contextTokens
                    prefixBudget = QwenStagePrefixCache.budget(roomBytes: admitted.roomBytes)
                    log("darkbloom-prefix-v1 rank=\(collective.rank) budget_bytes=\(prefixBudget ?? 0)"
                        + " room_bytes=\(admitted.roomBytes)")
                    log("darkbloom-resident-context-v1 rank=\(collective.rank) model=\(admission.runtimeModelID)"
                        + " limit=\(admission.profile.maximumContextTokens) admitted=\(admitted.contextTokens)"
                        + " charge_at_admitted=\(admitted.allowance.reservedBytes)"
                        + " transient_at_admitted=\(admitted.allowance.transientBytes)")
                    try checked()
                    if mode.isPhaseSplit || mode.usesSpeculativeHead {
                        // Sizes only, for whoever launched this worker.
                        let afterLoad = Memory.snapshot()
                        log("darkbloom-resident-load-v1 rank=\(collective.rank) mode=\(mode.rawValue)"
                            + " active_before=\(beforeLoad.activeMemory) cache_before=\(beforeLoad.cacheMemory)"
                            + " active_loaded=\(afterLoad.activeMemory) cache_loaded=\(afterLoad.cacheMemory)"
                            + " stages=\(producerStage == nil ? 1 : 2)")
                    }
                    let loadedIdentity = sha256(try canonicalJSONData([loadAgreement,
                        loaded.loaded.receipt.storageCommitmentSHA256, loaded.loaded.receipt.sourceParameterLayoutSHA256]))
                    _ = try requireQwenLongPrefillReadinessDigest(collective: collective,
                        material: { .residentLoaded(agreementFingerprint: loadedIdentity) },
                        disagreementMessage: "Resident peers did not load matching verified stage commitments", scope: .session(.loadedReady, "resident-loaded"), check: checked)
                    try checked()
                    activeLoaded = Memory.activeMemory
                    return try QwenLongPrefillCheckedBytes.sum([maximum.reservedBytes, prefill?.reservedBytes ?? 0,
                        split?.reservedBytes ?? 0])
                } catch {
                    // Prefer a recorded native fault over a secondary Swift
                    // validation/shape error before leaving this error scope.
                    try nativeError.check()
                    throw error
                }
            }
            // The prompt-prefix cache and, when the owner configured one, its
            // SSD tier for this plan and rank. Opening it sweeps the directories
            // of other plans under the tier's root on this rank.
            let prefixCache = QwenStagePrefixCache.fromEnvironment(launchEnvironment)
            if prefixCache.enabled, let loadedStage = stage {
                prefixCache.disk = QwenStagePrefixDiskTier.open(
                    configuration: .fromEnvironment(launchEnvironment, key: prefixSSDKey),
                    planScope: QwenStagePrefixDiskTier.planScope(planFingerprint: admission.plan.fingerprint,
                        artifactAggregateSHA256: loadedStage.loaded.receipt.verifiedAggregateSHA256,
                        storageCommitmentSHA256: loadedStage.loaded.receipt.storageCommitmentSHA256,
                        rankBuildSHA256: admission.configuration.identity.peers.map(\.buildSHA256),
                        generationMode: mode.rawValue, prefillSchedule: configuration.prefillSchedule.rawValue),
                    rank: collective.rank,
                    stagingEpoch: admission.configuration.identity.membershipEpoch.uuidString.lowercased(),
                    fault: fault?.prefixDisk)
            }
            let lifecycle = QwenLayerStageResidentLifecycle()
            try control.loaded()
            return .init(admission: admission, control: control, collective: collective,
                stage: stage!, capacity: capacity, lifecycle: lifecycle,
                generationMode: mode, producerStage: producerStage, speculativeHead: speculativeHead,
                speculativeTerms: speculativeTerms, qualificationFault: fault, prefixCache: prefixCache,
                servingContextTokens: servingContext, activeLoadedBytes: activeLoaded, prefixBudgetBytes: prefixBudget,
                batch: batch, linkProbe: linkProbe)
        } catch {
            let primary = error; control.fail(); speculativeHead = nil
            CBv2StageKVHost.uninstall(from: stage?.loaded); CBv2StageKVHost.uninstall(from: producerStage?.loaded)
            stage = nil; producerStage = nil
            do {
                try MLX.withError { nativeError in
                    Stream.gpu.synchronize(); Stream.cpu.synchronize()
                    Memory.clearCache(); try nativeError.check()
                }
                guard retired == nil, retiredProducer == nil else { throw ProbeError("Resident failed-load model remains retained") }
            } catch {
                // Process admission stays closed if local retirement is unknown.
                throw ProbeError("Resident load failed (\(primary)); local cleanup failed (\(error))")
            }
            // A failed native membership is not reused in this process, even
            // when local model cleanup succeeded. The worker must terminate.
            throw primary
        }
    }
}
