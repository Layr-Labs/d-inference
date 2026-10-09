import DarkbloomClusterProtocol
import Foundation
import MLX
import MLXNN

extension QwenResidentRuntime {
    /// `generationMode` nil takes the launcher's declaration from the process
    /// environment (`QwenResidentGenerationMode.environmentName`); absent there
    /// too, the pipeline. Both ranks must be given the same mode: it is part of
    /// the load agreement they compare before either stage is read.
    public static func load(_ configuration: QwenResidentLoadConfiguration,
                            generationMode declared: QwenResidentGenerationMode? = nil) throws -> QwenResidentRuntime {
        let mode = try declared ?? QwenResidentGenerationMode.admit(environment: ProcessInfo.processInfo.environment)
        // JACCL unless the launcher declared the single-Mac qualification socket.
        let transport = try ClusterTransport.admit(environment: ProcessInfo.processInfo.environment)
        // STAGING DIVERGENCE (recorded in the handoff source ledger, same as
        // Transport/Collective.swift): the research source accepted an optional
        // owner QwenResidentBootstrap producing a JACCLBootstrap group creator.
        // The pinned Darkbloom mlx-c does not expose
        // mlx_distributed_init_jaccl_with_bootstrap, so that path is not staged;
        // only direct backend initialization remains.
        let directory = configuration.modelDirectory
        let admission = try QwenResidentAdmission(configuration: configuration,
            configBytes: BoundedProbeInput.data(directory.appendingPathComponent("config.json"), maximumBytes: 1_048_576),
            manifestBytes: BoundedProbeInput.data(directory.appendingPathComponent("manifest.json"), maximumBytes: 4_194_304),
            environment: ProcessInfo.processInfo.environment, now: DispatchTime.now().uptimeNanoseconds,
            read: { try BoundedProbeInput.data($0, maximumBytes: $1) })
        let control = QwenResidentControl(deadline: configuration.deadlineUptimeNanoseconds)
        try QwenResidentProcessLease.shared.acquire()
        var stage: QwenResidentLoadedStage?
        var producerStage: QwenResidentLoadedStage?
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
            let agreementFields = mode.loadAgreementFields + transport.loadAgreementFields
            if !agreementFields.isEmpty { common = sha256(try canonicalJSONData([common] + agreementFields)) }
            let loadAgreement = common
            let capacity = try MLX.withError { nativeError in
                func checked() throws { try nativeError.check(); try control.check(); try nativeError.check() }
                do {
                    _ = try requireQwenLongPrefillReadinessDigest(collective: collective,
                        material: { .residentLoadIntent(agreementFingerprint: loadAgreement) },
                        disagreementMessage: "Resident load membership/source/Plan/mode differs", check: checked)
                    let beforeLoad = Memory.snapshot()
                    try autoreleasepool {
                        let value = try loadQwenResidentStage(admission, check: checked)
                        retired = value.loaded.model; stage = value
                    }
                    guard let loaded = stage else { throw ProbeError("Resident loader returned no stage") }
                    if mode == .phaseSplit, collective.rank == 1 {
                        // Rank 1 also holds the producer stage, admitted and loaded
                        // exactly as rank 0 loads it, so it owns every layer once
                        // rank 0 hands its request state over. No collective is
                        // created for it; only the rank in the environment differs.
                        var environment = ProcessInfo.processInfo.environment
                        for name in ["JACCL_RANK", "MLX_RANK"] where environment[name] != nil { environment[name] = "0" }
                        let producerAdmission = try QwenResidentAdmission(configuration: .init(
                                identity: configuration.identity, modelDirectory: configuration.modelDirectory, rank: 0,
                                stageCut: configuration.stageCut,
                                deadlineUptimeNanoseconds: configuration.deadlineUptimeNanoseconds,
                                allocatorPolicy: configuration.allocatorPolicy, prefillSchedule: configuration.prefillSchedule),
                            configBytes: admission.configBytes, manifestBytes: admission.manifestBytes,
                            environment: environment, now: DispatchTime.now().uptimeNanoseconds,
                            read: { try BoundedProbeInput.data($0, maximumBytes: $1) })
                        guard producerAdmission.plan.fingerprint == admission.plan.fingerprint,
                              producerAdmission.arithmeticSHA256 == admission.arithmeticSHA256,
                              producerAdmission.jaccl.fingerprint == admission.jaccl.fingerprint else {
                            throw ProbeError("Producer stage admission differs from this rank's Plan or arithmetic")
                        }
                        try autoreleasepool {
                            let value = try loadQwenResidentStage(producerAdmission, check: checked)
                            retiredProducer = value.loaded.model; producerStage = value
                        }
                        guard let producer = producerStage,
                              producer.loaded.receipt.storageCommitmentSHA256 == loaded.loaded.receipt.storageCommitmentSHA256,
                              producer.loaded.receipt.verifiedAggregateSHA256 == loaded.loaded.receipt.verifiedAggregateSHA256,
                              producer.loaded.receipt.sourceParameterLayoutSHA256 == loaded.loaded.receipt.sourceParameterLayoutSHA256 else {
                            throw ProbeError("Producer and consumer stages did not load matching verified commitments")
                        }
                    }
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
                    let split = try QwenResidentRuntime.phaseSplitAllowance(mode, admission: admission,
                        profile: loaded.profile, rank: collective.rank, promptCount: admission.profile.maximumPromptTokens)
                    try maximum.requireLive(
                        additionalNativeBytes: QwenLongPrefillCheckedBytes.sum([prefill?.extraNativeBytes ?? 0, split?.extraNativeBytes ?? 0]),
                        additionalHostBytes: QwenLongPrefillCheckedBytes.sum([prefill?.extraHostBytes ?? 0, split?.extraHostBytes ?? 0]))
                    try checked()
                    if mode == .phaseSplit {
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
                        disagreementMessage: "Resident peers did not load matching verified stage commitments", check: checked)
                    try checked()
                    return try QwenLongPrefillCheckedBytes.sum([maximum.reservedBytes, prefill?.reservedBytes ?? 0,
                        split?.reservedBytes ?? 0])
                } catch {
                    // Prefer a recorded native fault over a secondary Swift
                    // validation/shape error before leaving this error scope.
                    try nativeError.check()
                    throw error
                }
            }
            let lifecycle = try QwenLayerStageResidentLifecycle(maximumRequests: QwenResidentAdmission.maximumRequests)
            try control.loaded()
            return .init(admission: admission, control: control, collective: collective,
                stage: stage!, capacity: capacity, lifecycle: lifecycle,
                generationMode: mode, producerStage: producerStage)
        } catch {
            let primary = error; control.fail(); stage = nil; producerStage = nil
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
