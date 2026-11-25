import DarkbloomClusterProtocol
import Foundation
import MLX
import MLXNN

extension QwenResidentRuntime {
    public static func load(_ configuration: QwenResidentLoadConfiguration,
                            bootstrap: QwenResidentBootstrap? = nil) throws -> QwenResidentRuntime {
        try loadNative(configuration, bootstrap: bootstrap, protection: nil)
    }

    /// The ordinary path is unchanged. The explicit native experiment uses the
    /// same process lease, selected loader and request owner.
    static func loadNative(_ configuration: QwenResidentLoadConfiguration,
                           bootstrap: QwenResidentBootstrap? = nil,
                           protection initialProtection: CollectiveProtectionConfiguration?,
                           nativeStart: QwenProtectedNativeStart? = nil) throws -> QwenResidentRuntime {
        guard initialProtection == nil || nativeStart == nil else { throw ProbeError("Duplicate native protection source") }
        var protection = initialProtection
        // nil preserves the legacy experimental native TCP bootstrap.
        let nativeBootstrap = try bootstrap?.make(configuration: configuration)
        let directory = configuration.modelDirectory
        let admission = try QwenResidentAdmission(configuration: configuration,
            configBytes: BoundedProbeInput.data(directory.appendingPathComponent("config.json"), maximumBytes: 1_048_576),
            manifestBytes: BoundedProbeInput.data(directory.appendingPathComponent("manifest.json"), maximumBytes: 4_194_304),
            environment: ProcessInfo.processInfo.environment, now: DispatchTime.now().uptimeNanoseconds,
            read: { try BoundedProbeInput.data($0, maximumBytes: $1) })
        try protection?.requireBinding(epoch: configuration.identity.membershipEpoch, planSHA256: admission.plan.fingerprint)
        try nativeStart?.require(admission)
        let recordBudget: QwenProtectedRecordBudget? = try nativeStart.map { _ in try QwenProtectedRecordBudget() }
        let extraNative = nativeStart == nil ? 0 : QwenResidentProtectedExperiment.nativeAllowanceBytes
        let extraHost = nativeStart == nil ? 0 : QwenResidentProtectedExperiment.hostAllowanceBytes
        let control = QwenResidentControl(deadline: configuration.deadlineUptimeNanoseconds)
        try QwenResidentProcessLease.shared.acquire()
        var stage: QwenResidentLoadedStage?
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
            if let nativeStart {
                let establishedProtection: CollectiveProtectionConfiguration = try MLX.withError { nativeError in
                    do {
                        try nativeError.check(); try control.check()
                        guard let recordBudget else { throw ProbeError("Protected setup credit missing") }
                        let value = try nativeStart.establish(admission, recordBudget: recordBudget)
                        try nativeError.check(); try control.check(); try nativeError.check()
                        return value
                    } catch { try nativeError.check(); throw error }
                }
                protection = establishedProtection
            }
            let collective: Collective
            if let protection {
                collective = try .protected(transport: .jaccl, bootstrap: nativeBootstrap, configuration: protection)
            } else {
                collective = try Collective(transport: .jaccl, bootstrap: nativeBootstrap)
            }
            try admission.jaccl.requireUnchanged(environment: ProcessInfo.processInfo.environment,
                read: { try BoundedProbeInput.data($0, maximumBytes: $1) })
            try admission.jaccl.requireInitialized(rank: collective.rank, worldSize: collective.size, transport: collective.transport)
            let common = try admission.loadAgreementFingerprint()
            let capacity = try MLX.withError { nativeError in
                func checked() throws {
                    try nativeError.check(); try control.check()
                    if nativeStart != nil { try QwenProtectedResources.requireLive() }
                    try nativeError.check()
                }
                do {
                    _ = try requireQwenLongPrefillReadinessDigest(collective: collective,
                        material: { .residentLoadIntent(agreementFingerprint: common) },
                        disagreementMessage: "Resident load membership/source/Plan differs",
                        recordScope: { try .setup(.loadAgreement, agreementSHA256: common) }, check: checked)
                    try autoreleasepool {
                        let value = try loadQwenResidentStage(admission, additionalNativeBytes: extraNative,
                            additionalHostBytes: extraHost, check: checked)
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
                    try maximum.requireLive(additionalNativeBytes: QwenLongPrefillCheckedBytes.sum([prefill?.extraNativeBytes ?? 0, extraNative]),
                        additionalHostBytes: QwenLongPrefillCheckedBytes.sum([prefill?.extraHostBytes ?? 0, extraHost]))
                    try checked()
                    let loadedIdentity = sha256(try canonicalJSONData([common,
                        loaded.loaded.receipt.storageCommitmentSHA256, loaded.loaded.receipt.sourceParameterLayoutSHA256]))
                    _ = try requireQwenLongPrefillReadinessDigest(collective: collective,
                        material: { .residentLoaded(agreementFingerprint: loadedIdentity) },
                        disagreementMessage: "Resident peers did not load matching verified stage commitments",
                        recordScope: { try .setup(.loadedReady, agreementSHA256: loadedIdentity) }, check: checked)
                    try checked()
                    return try QwenLongPrefillCheckedBytes.sum([maximum.reservedBytes, prefill?.reservedBytes ?? 0, extraNative, extraHost])
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
                stage: stage!, capacity: capacity, lifecycle: lifecycle, protectedBudget: recordBudget)
        } catch {
            let primary = error; protection?.invalidate(); nativeStart?.connection.cancel(); control.fail(); stage = nil
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
