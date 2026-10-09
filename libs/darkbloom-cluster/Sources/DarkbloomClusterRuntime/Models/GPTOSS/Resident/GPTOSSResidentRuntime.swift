import DarkbloomClusterProtocol
import Foundation
import MLX
import MLXNN

/// Synchronous, process-local native owner of one rank of a resident GPT-OSS
/// pair, for the worker's private executor. It has the dense resident
/// runtime's contract: only cancel and readiness may run on the control
/// thread; concurrent reserve, start and shutdown refuse instead of
/// overlapping MLX work; a hard enclosing process deadline is required because
/// cooperative checks cannot interrupt a blocked native collective; on any
/// throw the caller withdraws this worker and fences its peer out of band.
/// `shutdown` releases only this process's weights.
public final class GPTOSSResidentRuntime {
    let admission: GPTOSSResidentAdmission
    let control: QwenResidentControl
    let collective: Collective
    let baseReady: ClusterWorkerReady
    /// Declared at load and bound into the load agreement with the peer.
    public let generationMode: QwenResidentGenerationMode
    private let operation = NSLock()
    private let lifecycle: QwenLayerStageResidentLifecycle
    private var stage: LoadedGPTOSSLayerStage?
    private weak var model: Module?
    private var reservation: Reservation?
    private var processLeaseOwned = true

    private struct Reservation {
        let request: QwenLayerStageGenerationRequest
        let allowance: GPTOSSResidentRequestAllowance
        let deadline: UInt64
        let prefillPolicy: QwenResidentPrefillPolicy
        let prefillAllowance: QwenGenerationPrefillAllowance?
        /// Present for a recording reservation only.
        let capture: QwenGenerationDiagnosticBudget?

        func requireLive() throws {
            try allowance.requireLive(
                additionalNativeBytes: QwenLongPrefillCheckedBytes.sum([
                    prefillAllowance?.extraNativeBytes ?? 0, capture?.extraNativeBytes ?? 0]),
                additionalHostBytes: QwenLongPrefillCheckedBytes.sum([
                    prefillAllowance?.extraHostBytes ?? 0, capture?.extraHostBytes ?? 0]))
        }
    }

    private init(admission: GPTOSSResidentAdmission, control: QwenResidentControl, collective: Collective,
                 stage: LoadedGPTOSSLayerStage, capacity: Int, lifecycle: QwenLayerStageResidentLifecycle,
                 generationMode: QwenResidentGenerationMode) {
        self.admission = admission; self.control = control; self.collective = collective
        self.stage = stage; model = stage.model; self.lifecycle = lifecycle
        self.generationMode = generationMode
        baseReady = .init(identity: admission.configuration.identity, rank: collective.rank,
            profile: admission.wireProfile, executionPlanSHA256: admission.plan.fingerprint,
            requestCapacityBytes: capacity)
    }

    public var readiness: ClusterWorkerReady? {
        guard control.available, (try? control.check()) != nil else { return nil }
        return baseReady
    }

    private var servingPolicy: QwenResidentPrefillPolicy {
        QwenResidentPrefillSelection.policy(admission.configuration.prefillSchedule)
    }

    private func prefillAllowance(_ policy: QwenResidentPrefillPolicy, promptCount: Int,
                                  chunkSize: Int) throws -> QwenGenerationPrefillAllowance? {
        try QwenResidentPrefillSelection.allowance(policy, rank: collective.rank,
            promptCount: promptCount, chunkSize: chunkSize, hiddenSize: admission.profile.hiddenSize,
            elementBytes: qwenStageWireElementBytes(admission.profile.activationDType),
            bound: QwenResidentResourceEnvironment.allocationBound)
    }

    private func captureBudget(reservedBytes: Int) throws -> QwenGenerationDiagnosticBudget {
        try .derive(rank: collective.rank, vocabularySize: admission.profile.vocabularySize,
            activationDType: admission.profile.activationDType, requestReservedBytes: reservedBytes,
            bound: QwenResidentResourceEnvironment.allocationBound)
    }

    /// The recording ceiling: the serving allowance at the largest request
    /// plus the capture terms. Available only while idle; it allocates nothing.
    @_spi(Benchmark) public func recordingReadiness() throws -> ClusterWorkerReady? {
        guard operation.try() else { throw ProbeError("Resident native operation is already active") }
        defer { operation.unlock() }
        guard control.available, (try? control.check()) != nil else { return nil }
        let base = try GPTOSSResidentRequestAllowance.derive(plan: admission.plan, rank: collective.rank,
            maximumTokens: admission.profile.maximumContextTokens, chunkSize: admission.profile.maximumChunkTokens)
        let capture = try captureBudget(reservedBytes: base.reservedBytes)
        let capacity = try QwenLongPrefillCheckedBytes.sum([baseReady.requestCapacityBytes,
            capture.extraHostBytes, capture.extraNativeBytes])
        return .init(identity: baseReady.identity, rank: baseReady.rank, profile: baseReady.profile,
            executionPlanSHA256: baseReady.executionPlanSHA256, requestCapacityBytes: capacity)
    }

    /// `generationMode` is the caller's declaration (the worker's
    /// `--generation-mode`); both ranks must be given the same one, and it
    /// must be in the registered model's row. `qualification` says whether
    /// this process may honour the qualification switches in its environment.
    public static func load(_ configuration: QwenResidentLoadConfiguration,
                            generationMode mode: QwenResidentGenerationMode = .pipeline,
                            qualification: QwenResidentQualificationSwitches = .refused) throws -> GPTOSSResidentRuntime {
        let environment = ProcessInfo.processInfo.environment
        try qualification.admit(environment: environment)
        // JACCL unless the single-Mac qualification socket was permitted and declared.
        var transport = ClusterTransport.jaccl
        if qualification.permitted { transport = try ClusterTransport.admit(environment: environment) }
        let directory = configuration.modelDirectory
        func read(_ url: URL, _ limit: Int) throws -> Data { try BoundedProbeInput.data(url, maximumBytes: limit) }
        let admission = try GPTOSSResidentAdmission(configuration: configuration,
            configBytes: read(directory.appendingPathComponent("config.json"), 1_048_576),
            manifestBytes: read(directory.appendingPathComponent("manifest.json"), 4_194_304),
            environment: environment, now: DispatchTime.now().uptimeNanoseconds, read: read)
        // The model's own row decides which modes it runs; nothing else does.
        guard admission.specification.supportedGenerationModes.contains(mode) else {
            throw ProbeError("Generation mode \(mode.rawValue) is not in the resident row of "
                + admission.specification.model.rawValue)
        }
        let control = QwenResidentControl(deadline: configuration.deadlineUptimeNanoseconds)
        try QwenResidentProcessLease.shared.acquire()
        var stage: LoadedGPTOSSLayerStage?
        weak var retired: Module?
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
                // Both ranks on this Mac, on the admitted coordinator endpoint.
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
            let loadAgreement = try admission.loadAgreementFingerprint(mode: mode, transport: transport)
            let capacity = try MLX.withError { nativeError in
                func checked() throws { try nativeError.check(); try control.check(); try nativeError.check() }
                do {
                    _ = try requireQwenLongPrefillReadinessDigest(collective: collective,
                        material: { .residentLoadIntent(agreementFingerprint: loadAgreement) },
                        disagreementMessage: "Resident GPT-OSS load membership/source/Plan/mode differs", check: checked)
                    let beforeLoad = Memory.snapshot()
                    let started = DispatchTime.now().uptimeNanoseconds
                    var verified = started
                    try autoreleasepool {
                        let source = try prepareGPTOSSResidentSource(directory: directory,
                            configuration: admission.configBytes, manifest: admission.manifestBytes,
                            specification: admission.specification, plan: admission.plan, check: checked)
                        verified = DispatchTime.now().uptimeNanoseconds
                        stage = try loadGPTOSSResidentStage(source: source, stageIndex: configuration.rank,
                            check: checked, constructed: { retired = $0 })
                    }
                    guard let loaded = stage else { throw ProbeError("Resident GPT-OSS loader returned no stage") }
                    let finished = DispatchTime.now().uptimeNanoseconds
                    let maximum = try GPTOSSResidentRequestAllowance.derive(plan: admission.plan, rank: collective.rank,
                        maximumTokens: admission.profile.maximumContextTokens,
                        chunkSize: admission.profile.maximumChunkTokens)
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
                    try maximum.requireLive(additionalNativeBytes: prefill?.extraNativeBytes ?? 0,
                                            additionalHostBytes: prefill?.extraHostBytes ?? 0)
                    try checked()
                    let afterLoad = Memory.snapshot()
                    // Sizes and durations only, for whoever launched this worker.
                    log("darkbloom-gptoss-resident-load-v1 rank=\(collective.rank) cut=\(configuration.stageCut)"
                        + " mode=\(mode.rawValue) loaded_tensor_bytes=\(loaded.receipt.loadedTensorBytes)"
                        + " active_before=\(beforeLoad.activeMemory) active_loaded=\(afterLoad.activeMemory)"
                        + " cache_loaded=\(afterLoad.cacheMemory)"
                        + " verify_ms=\((verified - started) / 1_000_000) load_ms=\((finished - verified) / 1_000_000)")
                    let loadedIdentity = sha256(try canonicalJSONData([loadAgreement,
                        loaded.receipt.storageCommitmentSHA256, loaded.receipt.sourceParameterLayoutSHA256]))
                    _ = try requireQwenLongPrefillReadinessDigest(collective: collective,
                        material: { .residentLoaded(agreementFingerprint: loadedIdentity) },
                        disagreementMessage: "Resident GPT-OSS peers did not load matching verified stage commitments",
                        check: checked)
                    try checked()
                    return try QwenLongPrefillCheckedBytes.sum([maximum.reservedBytes, prefill?.reservedBytes ?? 0])
                } catch {
                    // Prefer a recorded native fault over a secondary Swift error.
                    try nativeError.check()
                    throw error
                }
            }
            let lifecycle = try QwenLayerStageResidentLifecycle(maximumRequests: GPTOSSRegisteredSpecification.maximumRequests)
            try control.loaded()
            return .init(admission: admission, control: control, collective: collective, stage: stage!,
                capacity: capacity, lifecycle: lifecycle, generationMode: mode)
        } catch {
            let primary = error; control.fail(); stage = nil
            do {
                try MLX.withError { nativeError in
                    Stream.gpu.synchronize(); Stream.cpu.synchronize()
                    Memory.clearCache(); try nativeError.check()
                }
                guard retired == nil else { throw ProbeError("Resident GPT-OSS failed-load model remains retained") }
            } catch {
                // Process admission stays closed if local retirement is unknown.
                throw ProbeError("Resident GPT-OSS load failed (\(primary)); local cleanup failed (\(error))")
            }
            // A failed native membership is not reused in this process.
            throw primary
        }
    }

    /// Metadata and native resource reservation only; no request state or forward.
    /// Returned bytes are this rank's named allowance, not combined peer memory.
    public func reserve(requestID: UUID, request value: ClusterWorkerReservation) throws -> Int {
        try reserve(requestID: requestID, request: value, recording: false)
    }

    /// Charges the serving allowance plus both named capture terms. Both
    /// workers of a pair must use recording reservations.
    @_spi(Benchmark) public func reserveRecording(requestID: UUID, request value: ClusterWorkerReservation) throws -> Int {
        try reserve(requestID: requestID, request: value, recording: true)
    }

    private func reserve(requestID: UUID, request value: ClusterWorkerReservation, recording: Bool) throws -> Int {
        guard operation.try() else { throw ProbeError("Resident native operation is already active") }
        defer { operation.unlock() }
        let request = try admission.request(value, id: requestID, now: DispatchTime.now().uptimeNanoseconds)
        try control.check(); try control.reserve(requestID)
        do {
            guard stage != nil else { throw ProbeError("Resident model already released") }
            let allowance = try GPTOSSResidentRequestAllowance.derive(plan: admission.plan, rank: collective.rank,
                maximumTokens: request.maximumTokens, chunkSize: min(request.chunkSize, request.promptCount))
            let policy = servingPolicy
            let prefill = try prefillAllowance(policy, promptCount: request.promptCount, chunkSize: request.chunkSize)
            let capture = recording ? try captureBudget(reservedBytes: allowance.reservedBytes) : nil
            let total = try QwenLongPrefillCheckedBytes.sum([allowance.reservedBytes, prefill?.reservedBytes ?? 0,
                capture?.extraHostBytes ?? 0, capture?.extraNativeBytes ?? 0])
            let readiness = try baseReady.requestCapacityBytes
                + (recording ? QwenLongPrefillCheckedBytes.sum([capture!.extraHostBytes, capture!.extraNativeBytes]) : 0)
            guard total <= value.capacityLimitBytes, total <= readiness else {
                throw ProbeError("Resident reservation exceeds its additional owner capacity ceiling")
            }
            let reserved = Reservation(request: request, allowance: allowance, deadline: value.deadlineUptimeNanoseconds,
                prefillPolicy: policy, prefillAllowance: prefill, capture: capture)
            try reserved.requireLive()
            try control.check(deadline: value.deadlineUptimeNanoseconds)
            reservation = reserved
            return total
        } catch { control.fail(); throw error }
    }

    /// Only rank 0 invokes the callback, after both ranks commit and accept the
    /// token. False requests an agreed clean stop; a thrown callback is failure.
    public func start(requestID: UUID,
                      onCommittedToken: (Int, Int, Int) throws -> Bool) throws -> QwenResidentGenerationCompletion {
        try execute(requestID: requestID, recording: false, onCommittedToken: onCommittedToken) { completion, _ in completion }
    }

    /// Returns bounded CPU evidence only after bilateral retirement, local
    /// lifecycle exit and encoding. No tensor or model handle crosses this entry.
    @_spi(Benchmark) public func startRecording(requestID: UUID,
        onCommittedToken: (Int, Int, Int) throws -> Bool
    ) throws -> QwenResidentRecordingCompletion {
        try execute(requestID: requestID, recording: true, onCommittedToken: onCommittedToken) { completion, evidence in
            guard let evidence else { throw ProbeError("Recording request returned no diagnostic evidence") }
            return .init(completion: completion, encodedEvidence: try evidence.encoded())
        }
    }

    private func execute<Output>(requestID: UUID, recording: Bool,
        onCommittedToken: (Int, Int, Int) throws -> Bool,
        prepare: (QwenResidentGenerationCompletion, QwenGenerationDiagnosticEvidence?) throws -> Output
    ) throws -> Output {
        guard operation.try() else { throw ProbeError("Resident native operation is already active") }
        defer { operation.unlock() }
        guard let reserved = reservation, reserved.request.requestID == requestID else {
            throw ProbeError("Resident start has no matching reservation")
        }
        guard (reserved.capture != nil) == recording else {
            throw ProbeError("Resident start mode differs from its reservation")
        }
        do {
            let value = try QwenResidentRequestPublication.run(control: control, lifecycle: lifecycle,
                identity: .init(requestID: requestID, epoch: requestID,
                    recordedRequestFingerprint: reserved.request.fingerprint), deadline: reserved.deadline, body: {
                try autoreleasepool {
                    guard let stage else { throw ProbeError("Resident model already released") }
                    return try run(stage: stage, reserved: reserved, onCommittedToken: onCommittedToken)
                }
            }, prepare: { try prepare($0.0, $0.1) })
            // Output is fully prepared and control completed before this slot
            // is cleared. A thrown encode keeps the failed owner unavailable.
            reservation = nil
            return value
        } catch { control.fail(); throw error }
    }

    private func run(stage: LoadedGPTOSSLayerStage, reserved: Reservation,
                     onCommittedToken: (Int, Int, Int) throws -> Bool
    ) throws -> (QwenResidentGenerationCompletion, QwenGenerationDiagnosticEvidence?) {
        let receipt = stage.receipt
        let source = try QwenLayerStageWireSourceIdentity(
            sourceConfigurationSHA256: receipt.sourceConfigurationSHA256,
            artifactAggregateSHA256: receipt.verifiedAggregateSHA256,
            storageCommitmentSHA256: receipt.storageCommitmentSHA256,
            planFingerprint: admission.plan.fingerprint,
            producerStageFingerprint: admission.plan.stages[0].fingerprint)
        let agreement = try QwenLayerStageGenerationAgreement(request: reserved.request,
            membershipEpoch: admission.configuration.identity.membershipEpoch, source: source,
            consumerStageFingerprint: admission.plan.stages[1].fingerprint,
            rankBuildSHA256: admission.configuration.identity.peers.map(\.buildSHA256),
            numericalPolicySHA256: admission.arithmeticSHA256, prefillPolicy: reserved.prefillPolicy,
            compactDecode: generationMode == .pipelineCompactDecode)
        var lastResourceCheck: UInt64 = 0, ordinal = 0
        func check() throws {
            try control.check(deadline: reserved.deadline)
            let now = DispatchTime.now().uptimeNanoseconds
            if lastResourceCheck == 0 || now - lastResourceCheck >= 250_000_000 {
                try reserved.requireLive()
                lastResourceCheck = DispatchTime.now().uptimeNanoseconds
            }
            try control.check(deadline: reserved.deadline)
        }
        try check()
        let recording = try reserved.capture.map {
            try GPTOSSGenerationRecording(request: reserved.request, rank: collective.rank, budget: $0)
        }
        let started = DispatchTime.now().uptimeNanoseconds
        var firstToken: UInt64?
        let (result, evidence) = try runGPTOSSLayerStageGenerationRequest(loaded: stage, plan: admission.plan,
            agreement: agreement, collective: collective, recording: recording, onCommittedToken: { token in
                let current = ordinal; ordinal += 1
                if firstToken == nil { firstToken = DispatchTime.now().uptimeNanoseconds }
                return try onCommittedToken(current, token, reserved.request.promptCount + current)
            }, check: check)
        let finished = DispatchTime.now().uptimeNanoseconds
        guard result.bothRequestStatesRetired, (evidence != nil) == (reserved.capture != nil),
              let reason = ClusterWorkerFinishReason(rawValue: result.finishReason.rawValue) else {
            throw ProbeError("Resident generation returned without clean bilateral retirement")
        }
        // In-process durations, for whoever launched this worker. The clock is
        // this rank's own; neither figure is a serving latency.
        let memory = Memory.snapshot()
        log("darkbloom-gptoss-request-v1 rank=\(collective.rank) request=\(reserved.request.requestID.uuidString.lowercased())"
            + " prompt_tokens=\(reserved.request.promptCount) selected=\(result.selectedTokenIDs.count)"
            + " token_chain_sha256=\(result.tokenChainSHA256) ms=\((finished - started) / 1_000_000)"
            + " first_token_ms=\(firstToken.map { String(($0 - started) / 1_000_000) } ?? "none")"
            + " active=\(memory.activeMemory) peak=\(memory.peakMemory)")
        return (QwenResidentGenerationCompletion(requestID: reserved.request.requestID, finishReason: reason,
            selectedTokenIDs: result.selectedTokenIDs, completedFrames: result.completedFrames,
            committedTokens: result.committedTokens, tokenChainSHA256: result.tokenChainSHA256,
            bothRequestStatesRetired: true), evidence)
    }

    public func cancel(requestID: UUID) { control.cancel(requestID) }

    /// Local release only. On failure the external owner must retain and fence
    /// its peer and must not manufacture a successful retirement event.
    public func shutdown() throws {
        guard operation.try() else { throw ProbeError("Cannot release a running native request") }
        defer { operation.unlock() }
        try control.beginClose()
        do {
            try lifecycle.withModelRelease {
                try MLX.withError { error in
                    Stream.gpu.synchronize(); Stream.cpu.synchronize(); try error.check()
                    reservation = nil; stage = nil
                    guard model == nil else { throw ProbeError("Resident GPT-OSS model remains retained") }
                    Memory.clearCache(); try error.check()
                    Stream.gpu.synchronize(); Stream.cpu.synchronize(); try error.check()
                    let after = Memory.snapshot()
                    log("darkbloom-gptoss-resident-release-v1 rank=\(collective.rank) active=\(after.activeMemory) cache=\(after.cacheMemory)")
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
