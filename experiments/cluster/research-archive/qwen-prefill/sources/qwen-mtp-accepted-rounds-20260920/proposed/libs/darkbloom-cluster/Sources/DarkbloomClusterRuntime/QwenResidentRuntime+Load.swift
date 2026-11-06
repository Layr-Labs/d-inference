import DarkbloomClusterProtocol
import Foundation
import MLX
import MLXNN

extension QwenResidentRuntime {
    public static func load(_ configuration: QwenResidentLoadConfiguration,
                            bootstrap: QwenResidentBootstrap? = nil) throws -> QwenResidentRuntime {
        try loadImpl(configuration, bootstrap: bootstrap, mtpProbeMode: false)
    }

    @_spi(Benchmark) public static func loadForMTPProposalProbe(_ configuration: QwenResidentLoadConfiguration,
        bootstrap: QwenResidentBootstrap? = nil) throws -> QwenResidentRuntime {
        guard configuration.identity.modelID == QwenRegisteredDenseModel.qwen35NineB.rawValue,
              configuration.stageCut == 4, configuration.prefillSchedule == .serial,
              configuration.allocatorPolicy == .disableFreedBufferCache else {
            throw ProbeError("Private MTP probe load requires registered9B cut4, serial prefill and dedicated cache0 policy")
        }
        return try loadImpl(configuration, bootstrap: bootstrap, mtpProbeMode: true)
    }

    @_spi(Benchmark) public static func loadForMTPAcceptedValidation(_ configuration: QwenResidentLoadConfiguration,
        bootstrap: QwenResidentBootstrap? = nil) throws -> QwenResidentRuntime {
        guard configuration.identity.modelID == QwenRegisteredDenseModel.qwen35NineB.rawValue,
              configuration.stageCut == 4, configuration.prefillSchedule == .serial,
              configuration.allocatorPolicy == .disableFreedBufferCache, bootstrap != nil else {
            throw ProbeError("Accepted MTP requires registered9B cut4/serial/cache0 and the original owned bootstrap")
        }
        return try loadImpl(configuration, bootstrap: bootstrap, mtpProbeMode: false, mtpAcceptedMode: true)
    }

    private static func loadImpl(_ configuration: QwenResidentLoadConfiguration,
        bootstrap: QwenResidentBootstrap?, mtpProbeMode: Bool, mtpAcceptedMode: Bool = false) throws -> QwenResidentRuntime {
        // nil preserves the legacy experimental native TCP bootstrap.
        let nativeBootstrap = try bootstrap?.make(configuration: configuration)
        let directory = configuration.modelDirectory
        let admission = try QwenResidentAdmission(configuration: configuration,
            configBytes: BoundedProbeInput.data(directory.appendingPathComponent("config.json"), maximumBytes: 1_048_576),
            manifestBytes: BoundedProbeInput.data(directory.appendingPathComponent("manifest.json"), maximumBytes: 4_194_304),
            environment: ProcessInfo.processInfo.environment, now: DispatchTime.now().uptimeNanoseconds,
            read: { try BoundedProbeInput.data($0, maximumBytes: $1) })
        let control = QwenResidentControl(deadline: configuration.deadlineUptimeNanoseconds)
        try QwenResidentProcessLease.shared.acquire()
        var stage: QwenResidentLoadedStage?
        var mtpAssets: QwenResidentStageWithMTPAssets?
        weak var retired: Module?
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
            let collective = try Collective(transport: .jaccl, bootstrap: nativeBootstrap)
            try admission.jaccl.requireUnchanged(environment: ProcessInfo.processInfo.environment,
                read: { try BoundedProbeInput.data($0, maximumBytes: $1) })
            try admission.jaccl.requireInitialized(rank: collective.rank, worldSize: collective.size, transport: collective.transport)
            var common = try admission.loadAgreementFingerprint()
            if mtpProbeMode {
                common = sha256(try canonicalJSONData([common, "registered-qwen35-9b-single-unaccepted-proposal-v1",
                    "head-rank1", "replicated-input-embedding", "one-request"]))
            }
            if mtpAcceptedMode {
                common = sha256(try canonicalJSONData([common, QwenMTPAcceptedPolicy.registered9BDepth1Short.fingerprint,
                    "head-rank1", "replicated-input-embedding", "one-request"]))
            }
            let capacity = try MLX.withError { nativeError in
                func checked() throws { try nativeError.check(); try control.check(); try nativeError.check() }
                do {
                    _ = try requireQwenLongPrefillReadinessDigest(collective: collective,
                        material: { .residentLoadIntent(agreementFingerprint: common) },
                        disagreementMessage: "Resident load membership/source/Plan differs", check: checked)
                    try autoreleasepool {
                        if mtpProbeMode || mtpAcceptedMode, collective.rank == 1 {
                            let value = try loadQwenResidentStageWithMTPAssets(admission, check: checked)
                            mtpAssets = value; retired = value.target.loaded.model; stage = value.target
                        } else {
                            let value = try loadQwenResidentStage(admission, check: checked)
                            retired = value.loaded.model; stage = value
                        }
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
                        additionalHostBytes: prefill?.extraHostBytes ?? 0)
                    try checked()
                    let mtpCapacity: Int? = mtpProbeMode
                        ? try QwenResidentMTPProbeRuntime.maximumCapacity(admission: admission,
                            loaded: loaded, assets: mtpAssets, base: maximum) : nil
                    let acceptedCapacity: Int? = mtpAcceptedMode
                        ? try QwenMTPAcceptedRuntime.maximumCapacity(admission: admission, loaded: loaded, assets: mtpAssets) : nil
                    let loadedIdentity = sha256(try canonicalJSONData([common,
                        loaded.loaded.receipt.storageCommitmentSHA256, loaded.loaded.receipt.sourceParameterLayoutSHA256]))
                    _ = try requireQwenLongPrefillReadinessDigest(collective: collective,
                        material: { .residentLoaded(agreementFingerprint: loadedIdentity) },
                        disagreementMessage: "Resident peers did not load matching verified stage commitments", check: checked)
                    try checked()
                    return try acceptedCapacity ?? mtpCapacity ?? QwenLongPrefillCheckedBytes.sum([maximum.reservedBytes, prefill?.reservedBytes ?? 0])
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
                stage: stage!, capacity: capacity, lifecycle: lifecycle, mtpProbeMode: mtpProbeMode, mtpAcceptedMode: mtpAcceptedMode, mtpAssets: mtpAssets)
        } catch {
            let primary = error; control.fail(); mtpAssets = nil; stage = nil
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
