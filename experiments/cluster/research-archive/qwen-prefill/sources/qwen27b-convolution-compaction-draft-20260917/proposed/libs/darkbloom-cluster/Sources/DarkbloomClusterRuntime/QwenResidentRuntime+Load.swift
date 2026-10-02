import DarkbloomClusterProtocol
import Foundation
import MLX
import MLXNN

extension QwenResidentRuntime {
    public static func load(_ configuration: QwenResidentLoadConfiguration,
                            bootstrap: QwenResidentBootstrap? = nil) throws -> QwenResidentRuntime {
        try loadInternal(configuration, bootstrap: bootstrap, observeMemory: false)
    }

    /// Explicit private phase-memory entry; ordinary loads retain no recorder.
    @_spi(Benchmark) public static func loadPhaseMemoryObservation(_ configuration: QwenResidentLoadConfiguration,
        bootstrap: QwenResidentBootstrap? = nil, compactConvolutionState: Bool = false) throws -> QwenResidentRuntime {
        try loadInternal(configuration, bootstrap: bootstrap, observeMemory: true,
            compactConvolutionState: compactConvolutionState)
    }

    private static func loadInternal(_ configuration: QwenResidentLoadConfiguration,
        bootstrap: QwenResidentBootstrap?, observeMemory: Bool,
        compactConvolutionState: Bool = false) throws -> QwenResidentRuntime {
        guard !compactConvolutionState || observeMemory else {
            throw ProbeError("Convolution compaction requires the explicit observed owner")
        }
        // nil preserves the legacy experimental native TCP bootstrap.
        let nativeBootstrap = try bootstrap?.make(configuration: configuration)
        let directory = configuration.modelDirectory
        let admission = try QwenResidentAdmission(configuration: configuration,
            configBytes: BoundedProbeInput.data(directory.appendingPathComponent("config.json"), maximumBytes: 1_048_576),
            manifestBytes: BoundedProbeInput.data(directory.appendingPathComponent("manifest.json"), maximumBytes: 4_194_304),
            environment: ProcessInfo.processInfo.environment, now: DispatchTime.now().uptimeNanoseconds,
            read: { try BoundedProbeInput.data($0, maximumBytes: $1) })
        if observeMemory { try QwenResidentPhaseScope.require(admission) }
        let memoryBudget = observeMemory ? try QwenResidentPhaseScope.budget() : nil
        let control = QwenResidentControl(deadline: configuration.deadlineUptimeNanoseconds)
        try QwenResidentProcessLease.shared.acquire()
        var stage: QwenResidentLoadedStage?
        var memory: QwenResidentMemoryRecorder?
        weak var retired: Module?
        do {
            try control.check(); try QwenResidentResourceEnvironment.require(
                additionalHostBytes: memoryBudget?.requiredHostReservationBytes ?? 0)
            if let memoryBudget {
                memory = try QwenResidentMemoryRecorder(rank: configuration.rank, plan: admission.plan.fingerprint,
                    build: configuration.identity.peers[configuration.rank].buildSHA256, budget: memoryBudget)
            }
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
            let collective = try Collective(transport: .jaccl, bootstrap: nativeBootstrap)
            try admission.jaccl.requireUnchanged(environment: ProcessInfo.processInfo.environment,
                read: { try BoundedProbeInput.data($0, maximumBytes: $1) })
            try admission.jaccl.requireInitialized(rank: collective.rank, worldSize: collective.size, transport: collective.transport)
            let ordinaryCommon = try admission.loadAgreementFingerprint()
            let common = compactConvolutionState
                ? sha256(try canonicalJSONData([ordinaryCommon, "qwen27b-private-compact-convolution-v1"]))
                : ordinaryCommon
            let capacity = try MLX.withError { nativeError in
                func checked() throws { try nativeError.check(); try control.check(); try nativeError.check() }
                do {
                    _ = try requireQwenLongPrefillReadinessDigest(collective: collective,
                        material: { .residentLoadIntent(agreementFingerprint: common) },
                        disagreementMessage: "Resident load membership/source/Plan differs", check: checked)
                    try autoreleasepool {
                        let value = try loadQwenResidentStage(admission, memory: memory, check: checked)
                        retired = value.loaded.model; stage = value
                    }
                    guard let loaded = stage else { throw ProbeError("Resident loader returned no stage") }
                    let maximum = try QwenResidentRequestAllowance.derive(profile: loaded.profile, plan: admission.plan,
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
                    try maximum.requireLive(additionalNativeBytes: prefill?.extraNativeBytes ?? 0,
                        additionalHostBytes: QwenLongPrefillCheckedBytes.sum([prefill?.extraHostBytes ?? 0,
                            memoryBudget?.requiredHostReservationBytes ?? 0]),
                        memoryObserver: memory?.observer(.loadedRequestGuard))
                    try checked()
                    let loadedIdentity = sha256(try canonicalJSONData([common,
                        loaded.loaded.receipt.storageCommitmentSHA256, loaded.loaded.receipt.sourceParameterLayoutSHA256]))
                    _ = try requireQwenLongPrefillReadinessDigest(collective: collective,
                        material: { .residentLoaded(agreementFingerprint: loadedIdentity) },
                        disagreementMessage: "Resident peers did not load matching verified stage commitments", check: checked)
                    try checked()
                    return try QwenLongPrefillCheckedBytes.sum([maximum.reservedBytes, prefill?.reservedBytes ?? 0])
                } catch {
                    // Prefer a recorded native fault over a secondary Swift
                    // validation/shape error before leaving this error scope.
                    try nativeError.check()
                    throw error
                }
            }
            let lifecycle = try QwenLayerStageResidentLifecycle(maximumRequests: QwenResidentAdmission.maximumRequests)
            try control.loaded()
            try memory?.markReady(now: DispatchTime.now().uptimeNanoseconds)
            return .init(admission: admission, control: control, collective: collective,
                stage: stage!, capacity: capacity, lifecycle: lifecycle, phaseMemory: memory,
                compactConvolutionState: compactConvolutionState)
        } catch {
            let primary = error; control.fail(); stage = nil
            do {
                try MLX.withError { nativeError in
                    Stream.gpu.synchronize(); Stream.cpu.synchronize()
                    Memory.clearCache(); try nativeError.check()
                }
                guard retired == nil else { throw ProbeError("Resident failed-load model remains retained") }
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
