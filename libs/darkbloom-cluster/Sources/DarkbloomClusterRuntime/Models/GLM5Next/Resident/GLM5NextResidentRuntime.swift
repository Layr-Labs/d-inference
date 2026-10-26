import DarkbloomClusterProtocol
import DarkbloomClusterSecurity
import Foundation
import MLX

/// Private-selection native worker facade. Only readiness/cancel cross the
/// control thread; every native operation is synchronous and exclusive. Retain
/// this owner after a throw, fence the peer out of band, then call shutdown.
/// The enclosing worker must impose a hard process deadline for blocked native IO.
public final class GLM5NextResidentRuntime {
    private final class BoundStage {
        let binding: GLM5NextStageBinding
        init(_ binding: GLM5NextStageBinding) { self.binding = binding }
    }
    private struct Reservation {
        let request: QwenLayerStageGenerationRequest
        let deadline: UInt64
        /// What this request's prefix capture may add (0: it captures nothing).
        var prefixCaptureBytes = 0
    }

    private let admission: GLM5NextResidentAdmission
    private let control: QwenResidentControl
    private let operation = NSLock()
    private let lifecycle = QwenLayerStageResidentLifecycle()
    private let keepWarm = ClusterKeepWarm()
    private let processLease: QwenResidentProcessLease
    private let hooks: GLM5NextResidentLoadHooks
    /// This rank's prompt-prefix cache (on by default; `DARKBLOOM_CLUSTER_PREFIX_CACHE=off`
    /// turns it off), its budget set at load and its SSD tier opened with `prefixSSDKey`.
    public let prefixCache = QwenStagePrefixCache.fromEnvironment(ProcessInfo.processInfo.environment)
    private var prefixSSDKey: Data?
    private var resident: GLM5NextResidentStage?
    /// The stage's standing residency (MiMo's): without it every command
    /// buffer makes the stage's weights resident again and decode collapses.
    private var residency: ClusterStageResidency?
    private var bound: GLM5NextResidentStage.Borrow<BoundStage>?
    private var vision: GLM5NextResidentStage.Borrow<GLM5NextStageVision>?
    private var collective: Collective?
    private var activeDriver: GLM5NextPipelineGeneration?
    private var reservation: Reservation?
    private var baseReady: ClusterWorkerReady?
    private var loadAgreement: String?
    /// What this load measured of the link (`QwenTensorParallelLinkProbe`); reported at ready.
    private var linkProbe: ClusterWorkerLinkProbe?
    private var loadStarted = false
    private var startupWaitBudgetActive = false
    private var ownsProcessLease = false
    private var closed = false
    /// The shared host-memory watch of the current load or request (a new one
    /// per reservation, as every family keeps one per request allowance).
    private var memoryWatch = QwenDenseStageLoadWatch("GLM resident load")
    private var budget: GLM5NextRequestStateBudget?
    private var requestActiveBaseline: Int?
    private var loadPeak: (native: Int, host: Int, activeBaseline: Int)?
    /// Whether this process may honour qualification switches (the worker's
    /// explicit flag); every installed caller leaves it refused.
    private var qualification = QwenResidentQualificationSwitches.refused
    /// Qualification only: rank 1 writes one step line per selected row.
    private var recordsSteps = false

    /// Does no weight IO. Keeping construction separate from load means even a
    /// partial load has a caller-owned object on which to perform fenced cleanup.
    public convenience init(configuration: QwenResidentLoadConfiguration,
                            descriptor: GLM5NextResidentDescriptor,
                            resources: GLM5NextResidentResourceEnvelope) throws {
        try self.init(configuration: configuration, descriptor: descriptor, resources: resources,
            processLease: .shared, hooks: .init())
    }

    init(configuration: QwenResidentLoadConfiguration, descriptor: GLM5NextResidentDescriptor,
         resources: GLM5NextResidentResourceEnvelope, processLease: QwenResidentProcessLease,
         hooks: GLM5NextResidentLoadHooks, calibrationOnly: Bool = false) throws {
        guard resources.calibrationOnly == calibrationOnly else {
            throw ProbeError("Calibration resources cannot create a serving resident")
        }
        admission = try .init(configuration: configuration, descriptor: descriptor,
            resources: resources, now: DispatchTime.now().uptimeNanoseconds)
        control = .init(deadline: configuration.deadlineUptimeNanoseconds, lease: configuration.lease)
        self.processLease = processLease; self.hooks = hooks
    }

    /// The registered GLM row's serving resident for one rank: descriptor and
    /// resources from the artifact's own configuration and manifest, its
    /// pinned header inventory and this Mac's hardware. Does no weight IO;
    /// `load(dataPlane:)` follows on the worker's native executor.
    /// `prefixSSDKey`: the 32-byte key of this rank's prompt-prefix SSD tier,
    /// from the owner; nil leaves the tier off (`QwenStagePrefixDiskConfiguration`).
    public static func serving(_ configuration: QwenResidentLoadConfiguration,
                               qualification: QwenResidentQualificationSwitches = .refused,
                               prefixSSDKey: Data? = nil) throws -> GLM5NextResidentRuntime {
        let spec = try GLM5NextRegisteredSpecification.specification(runtimeModelID: configuration.identity.modelID)
        let directory = configuration.modelDirectory
        let config = try BoundedProbeInput.data(directory.appendingPathComponent("config.json"),
            maximumBytes: GLM5NextRegisteredSpecification.maximumConfigurationBytes)
        let manifest = try BoundedProbeInput.data(directory.appendingPathComponent("manifest.json"),
            maximumBytes: GLM5NextRegisteredSpecification.maximumManifestBytes)
        guard configuration.identity.configurationSHA256 == spec.configurationSHA256,
              configuration.identity.artifactSHA256 == spec.artifactSHA256,
              configuration.runtimeProfile == nil || configuration.runtimeProfile == spec.profileID
                || configuration.runtimeProfile == ClusterGLMImageCandidate.profileID,
              spec.supportedPrefillSchedules.contains(configuration.prefillSchedule),
              configuration.identity.peers.indices.contains(configuration.rank) else {
            throw ProbeError("GLM serving requires the registered model's identity, profile and schedule")
        }
        let includesVision = try ClusterGLMImageCandidate.includesVision(runtimeProfile: configuration.runtimeProfile,
            modelID: configuration.identity.modelID, artifact: configuration.identity.artifactSHA256,
            configuration: configuration.identity.configurationSHA256, manifest: spec.manifestSHA256)
        guard !includesVision || qualification.permitted else { throw ProbeError("GLM image LOAD requires explicit qualification") }
        let descriptor = try spec.descriptor(configuration: config, manifest: manifest, cut: configuration.stageCut, includesVision: includesVision)
        let inventory = try descriptor.inspectInventory(directory: directory)
        guard GLM5NextArtifactMetadata.fingerprint(inventory) == spec.inventorySHA256 else {
            throw ProbeError("GLM shard headers are not the registered inventory")
        }
        let resources = try GLM5NextServingResources.envelope(descriptor: descriptor, inventory: inventory,
            rank: configuration.rank, buildSHA256: configuration.identity.peers[configuration.rank].buildSHA256)
        let runtime = try GLM5NextResidentRuntime(configuration: configuration, descriptor: descriptor, resources: resources)
        runtime.qualification = qualification
        runtime.prefixSSDKey = prefixSSDKey
        return runtime
    }

    /// Keep-warm tier 1: one asynchronous pulse on a dedicated stream while
    /// idle (`ClusterKeepWarm.pulse`). Refuses while a native operation runs.
    public func keepWarmPulse() throws -> UInt64 {
        guard operation.try() else { throw ProbeError("GLM resident operation is already active") }
        defer { operation.unlock() }
        guard control.available, bound != nil else { throw ProbeError("Keep-warm needs an idle loaded GLM owner") }
        return keepWarm.pulse()
    }

    /// Keep-warm tier 2: one 1x16 exchange with the peer on the data plane
    /// while idle; both ranks are told by their owner, never during a request.
    public func dataPlanePing() throws -> UInt64 {
        guard operation.try() else { throw ProbeError("GLM resident operation is already active") }
        defer { operation.unlock() }
        guard control.available, bound != nil, let collective else {
            throw ProbeError("Keep-warm needs an idle loaded GLM owner")
        }
        return try ClusterKeepWarm.dataPlanePing(collective: collective, check: { try control.check() })
    }

    /// Local release for the installed worker, like every other family: the
    /// pair's owner fences the peer out of band, and on failure retains this
    /// process until it exits.
    public func shutdown() throws {
        try shutdown(peerFence: {}, check: {})
    }

    public var readiness: ClusterWorkerReady? {
        // loaded() publishes baseReady through the control lock. It is immutable
        // afterwards, including shutdown, so the control thread never races a write.
        guard control.available, (try? control.check()) != nil else { return nil }
        return baseReady
    }

    /// Production has no plaintext or local-socket fallback, including during
    /// qualification. The supplied credential is verified by the existing pinned
    /// data-plane exchange before either rank's payload reader runs.
    public func load(dataPlane credential: ClusterDataPlaneCredential) throws {
        guard operation.try() else { throw ProbeError("GLM resident operation is already active") }
        defer { operation.unlock() }
        guard !loadStarted, !closed else { throw ProbeError("GLM resident load is single-use") }
        do {
            try control.check(); try Task.checkCancellation()
            try beginLoad()
            let environment = ProcessInfo.processInfo.environment
            try qualification.admit(environment: environment)
            // Qualification only: record the host memory gate, or measure what it would refuse.
            if qualification.permitted, let mode = try QwenDenseStageLoadMeasurement.requested(environment: environment) {
                try QwenDenseStageLoadMeasurement.shared.enable(mode, permittedBy: qualification)
            }
            // The step lines change no arithmetic and no decision (MiMo's switch).
            if let value = environment[MiMoResidentRuntime.stepEvidenceEnvironmentName] {
                guard qualification.permitted, value == "on" else {
                    throw ProbeError("\(MiMoResidentRuntime.stepEvidenceEnvironmentName) is a qualification switch taking only on")
                }
                recordsSteps = true
            }
            let read: (URL, Int) throws -> Data = { try BoundedProbeInput.data($0, maximumBytes: $1) }
            let jaccl = try QwenResidentJACCLConfiguration.admit(environment: environment, read: read)
            guard jaccl.rank == admission.configuration.rank else { throw ProbeError("GLM launch rank differs from JACCL") }
            try jaccl.requireUnchanged(environment: ProcessInfo.processInfo.environment, read: read)
            let collective = try Collective(transport: .jaccl)
            try jaccl.requireUnchanged(environment: ProcessInfo.processInfo.environment, read: read)
            try jaccl.requireInitialized(rank: collective.rank, worldSize: collective.size, transport: collective.transport)
            try establishLoad(collective: collective, credential: credential, topologySHA256: jaccl.fingerprint)
            try collective.beginStartupWaitBudget(
                deadlineUptimeNanoseconds: try admission.configuration.startupWaitDeadline(
                    now: DispatchTime.now().uptimeNanoseconds))
            startupWaitBudgetActive = true
            try loadSelectedStage()
            try completeLoad()
        } catch {
            // Preserve the original failure. Ending the budget neither unpoisons
            // the cohort nor releases any model roots or process authority.
            try? finishStartupWaitBudget()
            poison(); throw error
        }
    }

    // Three real load phases, also used by same-process correctness fixtures:
    // exchange concurrently, construct graphs serially, exchange readiness. A
    // local-socket fixture cannot enter public load or claim physical qualification.
    func establishLoad(collective: Collective, credential: ClusterDataPlaneCredential,
                       topologySHA256: String) throws {
        guard self.collective == nil, !closed, collective.rank == admission.configuration.rank,
              collective.size == 2, credential.rank == collective.rank,
              credential.epoch == admission.configuration.identity.membershipEpoch else {
            throw ProbeError("GLM load collective/credential differs from launch identity")
        }
        do {
            if !loadStarted { try beginLoad() }
            self.collective = collective
            try check()
            // Every load over the cable measures the link as tensor parallel uses it
            // (`QwenTensorParallelLinkProbe`), so the planner can choose it for this
            // pair; bound into the agreement so both ranks measure it.
            let probesLink = collective.transport != .localSocketTest
            let plain = try admission.loadAgreement(jacclFingerprint: topologySHA256, transport: collective.transport)
            let agreement = probesLink
                ? sha256(try canonicalJSONData([plain, QwenTensorParallelLinkProbe.loadAgreementField])) : plain
            // Metadata/capacity refusal precedes even streamed artifact hashing.
            let d = admission.descriptor, r = admission.resources
            let quote = try r.quote(descriptor: d, maximumBufferBytes: GPU.deviceInfo().maxBufferSize,
                allocationBound: QwenResidentResourceEnvironment.allocationBound)
            let budget = quote.request
            self.budget = budget
            resident = try .init(directory: admission.configuration.modelDirectory,
                expectedIdentity: d.artifactIdentity, artifactAggregateSHA256: d.artifactAggregateSHA256,
                storage: d.storage, stageIndex: collective.rank, cut: d.cut, includeMTP: false,
                executionPolicy: d.executionPolicy, capacityLimitBytes: r.loadCapacityBytes,
                executionStateReserveBytes: budget.nativeBytes - budget.workspaceNativeBytes,
                workspaceReserveBytes: budget.workspaceNativeBytes, hooks: hooks,
                // The facade already owns the process lease before bootstrap.
                // The lower-level owner retains its own non-reopenable lease.
                processLease: QwenResidentProcessLease(), includeVision: d.includesVision)
            guard let resident else { throw ProbeError("GLM resident preparation failed") }
            let expected = quote.load
            guard expected.storageCommitmentSHA256 == resident.resources.storageCommitmentSHA256,
                  expected.summary == resident.resources.summary else {
                throw ProbeError("GLM request inventory differs from actual selected-stage metadata")
            }
            loadPeak = (quote.peak.nativeBytes, quote.peak.hostBytes, Memory.activeMemory)
            try requireLoadResources()
            try ClusterDataPlaneAgreement.establish(collective: collective, credential: credential,
                loadAgreement: agreement, tamper: nil, tensorParallelSeal: probesLink, check: { try self.check() })
            guard collective.workerDataPlane?.peerVerified == true else {
                throw ProbeError("GLM load requires an authenticated peer")
            }
            _ = try requireQwenLongPrefillReadinessDigest(collective: collective,
                material: { .residentLoadIntent(agreementFingerprint: agreement) },
                disagreementMessage: "GLM descriptor/source/cut/policy/peers differ before load",
                scope: .session(.loadAgreement, "glm-resident-load-intent"), check: { try self.check() })
            if probesLink {
                // The link, before any weight is read.
                let probe = try QwenTensorParallelLinkProbe.measure(onPipeline: collective, keyed: true,
                    loadAgreement: agreement, hiddenSize: d.configuration.textConfig.hiddenSize,
                    chunkTokens: d.profile.maximumChunkTokens, check: { try self.check() })
                linkProbe = probe
                log(QwenTensorParallelLinkProbe.line(probe, rank: collective.rank))
            }
            loadAgreement = agreement
        } catch { poison(); throw error }
    }

    func loadSelectedStage() throws {
        do {
            guard loadAgreement != nil, let resident else { throw ProbeError("GLM load lacks authenticated peer agreement") }
            try resident.load { try self.check(); try self.requireLoadResources() }
            loadPeak = nil
        } catch { poison(); throw error }
    }

    func completeLoad() throws {
        do {
            guard baseReady == nil, let resident, resident.phase == .loaded,
                  let collective, let loadAgreement, let receipt = resident.receipt else {
                throw ProbeError("GLM ready requires a verified selected-stage receipt")
            }
            try check()
            try admission.configuration.allocatorPolicy.prepareReady(synchronize: {
                try MLX.withError { error in
                    Stream.gpu.synchronize(); Stream.cpu.synchronize(); try error.check()
                }
            }, snapshot: {
                let value = Memory.snapshot()
                return .init(activeBytes: value.activeMemory, cachedBytes: value.cacheMemory, peakBytes: value.peakMemory)
            }, clearCache: {
                try MLX.withError { error in Memory.clearCache(); try error.check() }
            }, check: { try self.check() })
            try requireResources()
            guard let budget else { throw ProbeError("GLM ready requires its validated request budget") }
            do {
                try MLX.withError { error in
                    Stream.gpu.synchronize(); Stream.cpu.synchronize(); try error.check()
                    residency = try ClusterStageResidency(bytes: try QwenLongPrefillCheckedBytes.sum([
                        receipt.selectedPayloadBytes, budget.reservedBytes]))
                }
                log("darkbloom-glm-resident-load-v1 rank=\(collective.rank) cut=\(admission.descriptor.cut)"
                    + " loaded_tensor_bytes=\(receipt.selectedPayloadBytes)"
                    + " wired_limit=\(residency?.receipt.appliedBytes ?? 0)"
                    + " wired_limit_ceiling=\(residency?.receipt.ceilingBytes ?? 0)")
            }
            if prefixCache.enabled {
                // Half the room beside the request charge, as every family keeps it.
                let room = try ClusterStagePrefixBudget.roomBytes(chargeBytes: budget.reservedBytes)
                prefixCache.setBudget(QwenStagePrefixCache.budget(roomBytes: room))
                prefixCache.disk = QwenStagePrefixDiskTier.open(
                    configuration: .fromEnvironment(ProcessInfo.processInfo.environment, key: prefixSSDKey),
                    planScope: QwenStagePrefixDiskTier.planScope(planFingerprint: receipt.source.planFingerprint,
                        artifactAggregateSHA256: receipt.source.artifactAggregateSHA256,
                        storageCommitmentSHA256: receipt.source.storageCommitmentSHA256,
                        rankBuildSHA256: admission.configuration.identity.peers.map(\.buildSHA256),
                        generationMode: QwenResidentGenerationMode.pipeline.rawValue,
                        prefillSchedule: admission.configuration.prefillSchedule.rawValue),
                    rank: collective.rank,
                    stagingEpoch: admission.configuration.identity.membershipEpoch.uuidString.lowercased())
                log("darkbloom-prefix-v1 rank=\(collective.rank) family=glm budget_bytes=\(prefixCache.budgetBytes)"
                    + " room_bytes=\(room) ssd=\(prefixCache.disk != nil)")
            }
            bound = try resident.borrowComponent { stage, mtp in
                guard mtp == nil, stage.model.plan.configuration == admission.descriptor.configuration.textConfig,
                      stage.model.executionPolicy == admission.descriptor.executionPolicy,
                      stage.model.plan.layers == (collective.rank == 0 ? 0..<admission.descriptor.cut
                        : admission.descriptor.cut..<admission.descriptor.configuration.textConfig.hiddenLayers),
                      !stage.model.plan.loadsMTPEmbedding else {
                    throw ProbeError("GLM loaded stage differs from the selected construction")
                }
                return BoundStage(stage)
            }
            if admission.descriptor.includesVision && collective.rank == 0 {
                vision = try resident.borrowVision()
            }
            let contract = bound!.value.binding.contract
            let loaded = sha256(try canonicalJSONData([loadAgreement, contract.source.planFingerprint,
                contract.source.storageCommitmentSHA256, contract.numericalPolicySHA256]
                + contract.stageFingerprints))
            _ = try requireQwenLongPrefillReadinessDigest(collective: collective,
                material: { .residentLoaded(agreementFingerprint: loaded) },
                disagreementMessage: "GLM verified loaded source/cut/policy differs",
                scope: .session(.loadedReady, "glm-resident-loaded"), check: { try self.check() })
            guard receipt.source.planFingerprint == contract.source.planFingerprint else {
                throw ProbeError("GLM resident receipt differs from the borrowed binding")
            }
            try requireResources()
            try check()
            // Restore steady-state progress limits before READY is observable.
            try finishStartupWaitBudget()
            baseReady = .init(identity: admission.configuration.identity, rank: collective.rank,
                profile: admission.wireProfile, executionPlanSHA256: contract.source.planFingerprint,
                requestCapacityBytes: admission.resources.requestCapacityBytes, dataPlane: collective.workerDataPlane,
                // The context its LOAD charged, when below the profile's: the
                // pair refuses a longer request before asking (`request`).
                servingContextTokens: admission.descriptor.memoryProfile.maximumContextTokens
                    < admission.descriptor.profile.maximumContextTokens
                    ? admission.descriptor.memoryProfile.maximumContextTokens : nil,
                linkProbe: linkProbe)
            try check()
            try control.loaded()
        } catch { poison(); throw error }
    }

    public func reserve(requestID: UUID, request value: ClusterWorkerReservation) throws -> Int {
        guard operation.try() else { throw ProbeError("GLM resident operation is already active") }
        defer { operation.unlock() }
        let request = try admission.request(value, id: requestID, now: DispatchTime.now().uptimeNanoseconds)
        try check(); try control.reserve(requestID)
        return try control.reserving(requestID, rank: admission.configuration.rank,
                                     deadline: value.deadlineUptimeNanoseconds) {
            guard bound != nil else { throw ProbeError("GLM resident model is unavailable") }
            let current = try admission.resources.budget(descriptor: admission.descriptor)
            guard current == budget, current.reservedBytes <= value.capacityLimitBytes else {
                throw ProbeError("GLM request allocator quotation changed or exceeds owner capacity")
            }
            memoryWatch = QwenDenseStageLoadWatch("GLM resident request")
            requestActiveBaseline = nil
            var reserved = Reservation(request: request, deadline: value.deadlineUptimeNanoseconds)
            // Only what this request's capture adds after the prefix this rank
            // holds for it, under the scope its agreement will key the cache by.
            if request.stillImages == nil, prefixCache.enabled, let contract = bound?.value.binding.contract {
                reserved.prefixCaptureBytes = prefixCache.captureLimit(scope: qwenStagePrefixScope(source: contract.source,
                    numericalPolicySHA256: contract.numericalPolicySHA256, request: request),
                    tokens: request.promptTokenIDs, chunkSize: request.chunkSize)
            }
            // Kept prefixes give way before a reservation is refused for memory,
            // and this request's own capture is optional.
            do {
                try prefixCache.yieldingMemory { try requireResources(additionalNativeBytes: reserved.prefixCaptureBytes) }
            } catch where reserved.prefixCaptureBytes > 0 {
                log("darkbloom-prefix-v1 rank=\(admission.configuration.rank) family=glm capture-dropped"
                    + " bytes=\(reserved.prefixCaptureBytes): \(error)")
                reserved.prefixCaptureBytes = 0
                try prefixCache.yieldingMemory { try requireResources() }
            }
            try check(deadline: value.deadlineUptimeNanoseconds)
            prefixCache.admitCapture(prefixCache.enabled ? reserved.prefixCaptureBytes : nil)
            reservation = reserved
            return current.reservedBytes
        }
    }

    public func releaseReservation(requestID: UUID) throws {
        guard operation.try() else { throw ProbeError("GLM resident operation is already active") }
        defer { operation.unlock() }
        guard reservation?.request.requestID == requestID, control.withdraw(requestID) else {
            throw ProbeError("GLM release requires its unstarted reservation")
        }
        reservation = nil; prefixCache.admitCapture(nil)
    }

    public func start(requestID: UUID,
                      onCommittedToken: (Int, Int, Int) throws -> Bool) throws -> QwenResidentGenerationCompletion {
        guard operation.try() else { throw ProbeError("GLM resident operation is already active") }
        defer { operation.unlock() }
        guard let reserved = reservation, reserved.request.requestID == requestID else {
            throw ProbeError("GLM start requires its exact reservation")
        }
        do {
            let completion = try QwenResidentRequestPublication.run(control: control, lifecycle: lifecycle,
                identity: .init(requestID: requestID, epoch: requestID,
                    recordedRequestFingerprint: reserved.request.fingerprint), deadline: reserved.deadline, body: {
                try autoreleasepool { try run(reserved, onCommittedToken: onCommittedToken) }
            }, prepare: { $0 })
            reservation = nil
            return completion
        } catch { poison(); throw error }
    }

    private func run(_ reserved: Reservation, onCommittedToken: (Int, Int, Int) throws -> Bool) throws
        -> QwenResidentGenerationCompletion {
        guard let bound, let collective else { throw ProbeError("GLM resident was released") }
        let stage = bound.value.binding, contract = stage.contract
        let unplanned = try QwenLayerStageGenerationAgreement(request: reserved.request,
            membershipEpoch: admission.configuration.identity.membershipEpoch, source: contract.source,
            consumerStageFingerprint: contract.stageFingerprints[1],
            rankBuildSHA256: admission.configuration.identity.peers.map(\.buildSHA256),
            numericalPolicySHA256: contract.numericalPolicySHA256)
        try GLM5NextPipelineGeneration.requireSupported(unplanned)
        try check(deadline: reserved.deadline); try requireResources()
        guard try admission.resources.budget(descriptor: admission.descriptor) == budget else {
            throw ProbeError("GLM request resource bounds changed after reservation")
        }
        requestActiveBaseline = Memory.activeMemory
        // Both ranks agree what prompt prefix to reuse and restore it, before
        // the first frame; anything else prefills from zero on both.
        let cacheBefore = prefixCache.bytesInUse
        let planned = try agreeGLM5NextStagePrefixPlan(cache: reserved.request.stillImages == nil ? prefixCache : nil, stage: stage, agreement: unplanned,
            collective: collective, check: { try self.check(deadline: reserved.deadline) })
        // A state read from the SSD tier is kept resident too; that is the
        // cache's growth, not this request's.
        requestActiveBaseline = requestActiveBaseline.map { $0 + max(0, prefixCache.bytesInUse - cacheBefore) }
        let agreement = planned.agreement, session = planned.session
        let captureLimit = beginClusterStagePrefixCapture(cache: prefixCache, capture: session.prefixCapture)
        defer { prefixCache.endCapture() }
        let driver = try GLM5NextPipelineGeneration(session: session, collective: collective)
        activeDriver = driver
        // The driver's generation agreement binds pixels/spans/config on both
        // ranks before rank 0 can prepare native media in the first frame.
        if let media = reserved.request.stillImages, collective.rank == 0 {
            guard let vision else { throw ProbeError("GLM image request lacks its resident tower") }
            session.imageFeatures = GLM5NextStageImageFeatures(media: media, owner: vision.value)
        }
        var ordinal = 0, lastCheck: UInt64 = 0
        var captureCharge = reserved.prefixCaptureBytes
        let result = try driver.run(onCommittedToken: { token in
            let current = ordinal; ordinal += 1
            return try onCommittedToken(current, token, reserved.request.promptCount + current)
        }, onSelectedRow: recordsSteps ? { index, boundary, row in
            // Rank 1's row as qualification evidence, in MiMo's step format.
            let bytes = row.asData().data, dtype = String(describing: row.dtype)
            log(MiMoStepEvidence(ordinal: index, boundarySHA256: boundary, rowSHA256: sha256(bytes), rowDType: dtype,
                top: try MiMoStepEvidence.candidates(rowBytes: bytes, dtype: dtype)).line(rank: collective.rank))
        } : nil, check: {
            try self.check(deadline: reserved.deadline)
            let now = DispatchTime.now().uptimeNanoseconds
            if lastCheck == 0 || now - lastCheck >= 250_000_000 {
                // Kept prefixes give way first, then this request's own capture.
                captureCharge = try QwenResidentRequestExecution.checkRunning(captureBytes: captureCharge,
                    prefixCache: self.prefixCache, rank: collective.rank,
                    live: { try self.requireResources(additionalNativeBytes: $0) })
                lastCheck = now
            }
            try self.check(deadline: reserved.deadline)
        })
        guard result.bothRequestStatesRetired,
              let reason = ClusterWorkerFinishReason(rawValue: result.finishReason.rawValue) else {
            throw ProbeError("GLM request lacks bilateral retirement")
        }
        activeDriver = nil
        requestActiveBaseline = nil
        let stored = storeClusterStagePrefix(cache: prefixCache, capture: session.prefixCapture,
            agreement: agreement, rank: collective.rank, captureLimit: captureLimit, family: "glm", skippedKey: "skipped")
        if prefixCache.enabled {
            log("darkbloom-prefix-v1 rank=\(collective.rank) family=glm request=\(reserved.request.requestID.uuidString.lowercased())"
                + " prompt=\(reserved.request.promptCount) reused=\(planned.summary.reusedPromptTokens)"
                + " stored=\(stored.map(String.init).joined(separator: "_")) entries=\(prefixCache.count)"
                + " tier=\(planned.summary.restoredTier ?? "none")")
        }
        return .init(requestID: reserved.request.requestID, finishReason: reason,
            selectedTokenIDs: result.selectedTokenIDs, completedFrames: result.completedFrames,
            committedTokens: result.committedTokens, tokenChainSHA256: result.tokenChainSHA256,
            bothRequestStatesRetired: true, reusedPromptTokens: planned.summary.reusedPromptTokens,
            storedPromptFrontiers: stored)
    }

    public func cancel(requestID: UUID) { control.cancel(requestID) }

    private func beginLoad() throws {
        try processLease.acquire()
        ownsProcessLease = true; loadStarted = true
        try admission.resources.requireExecutionEnvironment(admission.resources.executionEnvironmentSHA256)
        try QwenResidentResourceEnvironment.requirePower()
        try MLX.withError { error in
            try admission.configuration.allocatorPolicy.configure(setCacheLimit: { Memory.cacheLimit = $0 },
                check: { try error.check(); try self.check(); try error.check() })
        }
    }

    /// No cancellation/deadline from the failed request is reused for cleanup.
    /// A failed fence retains the driver, its cache, borrow and resident roots.
    /// Once a stage was borrowed, successful shutdown still requires process exit;
    /// it never reopens the resident process lease for a replacement model.
    public func shutdown(peerFence: () throws -> Void, check cleanupCheck: () throws -> Void) throws {
        guard operation.try() else { throw ProbeError("Cannot shut down an active GLM operation") }
        defer { operation.unlock() }
        guard !closed else { return }
        if !loadStarted { control.fail() }
        try control.beginClose()
        do {
            try peerFence(); try cleanupCheck()
            if let activeDriver {
                try activeDriver.closeAfterPeerFence(peerFence: {}, check: cleanupCheck)
                self.activeDriver = nil
            }
            try lifecycle.withModelRelease {
                if ownsProcessLease {
                    try MLX.withError { error in
                        Stream.gpu.synchronize(); Stream.cpu.synchronize()
                        try error.check(); try cleanupCheck(); try error.check()
                    }
                }
                // Records already queued for the SSD are finished first (bounded):
                // they are what a restarted pair restores.
                prefixCache.disk?.close()
                prefixCache.sweep()
                bound = nil; vision = nil; reservation = nil
                try residency?.end(); residency = nil
                try resident?.close(peerFence: {}, check: cleanupCheck)
            }
            if ownsProcessLease, resident?.requiresProcessExit != true {
                processLease.release(); ownsProcessLease = false
            }
            control.closed(); closed = true
        } catch { poison(); throw error }
    }

    private func check(deadline: UInt64? = nil) throws {
        try Task.checkCancellation(); try control.check(deadline: deadline)
    }

    /// `additionalNativeBytes`: a request's prefix capture, beyond its quotation.
    private func requireResources(additionalNativeBytes: Int = 0) throws {
        guard let budget else { throw ProbeError("GLM request has no validated memory budget") }
        try admission.resources.requireExecutionEnvironment(admission.resources.executionEnvironmentSHA256)
        try requireMemory(nativeBytes: try GLM5NextStageLoadResources.sum([budget.nativeBytes, additionalNativeBytes]),
            hostBytes: budget.hostBytes, activeBaseline: requestActiveBaseline)
    }

    private func requireLoadResources() throws {
        guard let loadPeak else { throw ProbeError("GLM load has no native/host quotation") }
        try admission.resources.requireExecutionEnvironment(admission.resources.executionEnvironmentSHA256)
        try requireMemory(nativeBytes: loadPeak.native, hostBytes: loadPeak.host,
            activeBaseline: loadPeak.activeBaseline)
    }

    private func requireMemory(nativeBytes: Int, hostBytes: Int, activeBaseline: Int?) throws {
        try QwenResidentResourceEnvironment.requirePower()
        let os = try QwenDenseStageLoadResources.observeOS()
        let native = QwenDenseStageLoadResources.observeNative()
        // Only native growth can consume a native reservation. Host/Foundation
        // storage keeps its full separate allowance throughout the operation.
        let grown = activeBaseline.map { max(0, native.activeBytes - $0) } ?? 0
        let remaining = max(0, nativeBytes - grown)
        do {
            _ = try memoryWatch.admits(os, bytes: GLM5NextStageLoadResources.sum([remaining, hostBytes,
                    QwenDenseStageLoadPolicy.loadingHeadroomBytes(physicalMemoryBytes: os.physicalMemoryBytes)]),
                now: DispatchTime.now().uptimeNanoseconds)
        } catch {
            // Numeric reservation context explains a refusal without exposing model input.
            throw ProbeError("\(error); GLM memory context bytes: nativeReservation=\(nativeBytes) "
                + "hostReservation=\(hostBytes) activeBaseline=\(activeBaseline ?? 0) "
                + "active=\(native.activeBytes) cache=\(native.cacheBytes) "
                + "nativeGrowth=\(grown) remainingNative=\(remaining)")
        }
        let needed = try GLM5NextStageLoadResources.sum([native.activeBytes, native.cacheBytes, remaining,
            QwenDenseStageLoadPolicy.allocatorHeadroomBytes])
        guard needed <= native.allocatorLimitBytes else { throw ProbeError("GLM request exceeds live allocator capacity") }
    }

    private func finishStartupWaitBudget() throws {
        guard startupWaitBudgetActive else { return }
        guard let collective else { throw ProbeError("Startup wait has no owned collective") }
        try collective.endStartupWaitBudget()
        startupWaitBudgetActive = false
    }

    private func poison() { control.fail(); collective?.invalidateDataPlane() }

    deinit {
        if !closed {
            control.fail()
            // An abandoned failed driver can still own tentative caches. Keep
            // those as well as the resident roots until process exit.
            let owners: [AnyObject?] = [resident, bound, vision, activeDriver, collective,
                ownsProcessLease ? processLease : nil]
            GLM5NextAbandonedRuntimes.shared.retain(owners.compactMap { $0 })
        }
    }
}

private final class GLM5NextAbandonedRuntimes: @unchecked Sendable {
    static let shared = GLM5NextAbandonedRuntimes()
    private let lock = NSLock()
    private var owners: [AnyObject] = []
    func retain(_ values: [AnyObject]) {
        lock.lock(); defer { lock.unlock() }; owners.append(contentsOf: values)
    }
}
