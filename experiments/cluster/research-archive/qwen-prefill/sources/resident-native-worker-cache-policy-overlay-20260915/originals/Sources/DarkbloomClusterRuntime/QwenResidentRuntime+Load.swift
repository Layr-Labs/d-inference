import DarkbloomClusterProtocol
import Foundation
import MLX
import MLXNN

extension QwenResidentRuntime {
    public static func load(_ configuration: QwenResidentLoadConfiguration) throws -> QwenResidentRuntime {
        let directory = configuration.modelDirectory
        let admission = try QwenResidentAdmission(configuration: configuration,
            configBytes: BoundedProbeInput.data(directory.appendingPathComponent("config.json"), maximumBytes: 1_048_576),
            manifestBytes: BoundedProbeInput.data(directory.appendingPathComponent("manifest.json"), maximumBytes: 4_194_304),
            environment: ProcessInfo.processInfo.environment, now: DispatchTime.now().uptimeNanoseconds,
            read: { try BoundedProbeInput.data($0, maximumBytes: $1) })
        let control = QwenResidentControl(deadline: configuration.deadlineUptimeNanoseconds)
        try QwenResidentProcessLease.shared.acquire()
        var stage: QwenResidentLoadedStage?
        weak var retired: Module?
        do {
            try control.check(); try QwenResidentResourceEnvironment.require()
            try admission.jaccl.requireUnchanged(environment: ProcessInfo.processInfo.environment,
                read: { try BoundedProbeInput.data($0, maximumBytes: $1) })
            let collective = try Collective(transport: .jaccl)
            try admission.jaccl.requireUnchanged(environment: ProcessInfo.processInfo.environment,
                read: { try BoundedProbeInput.data($0, maximumBytes: $1) })
            try admission.jaccl.requireInitialized(rank: collective.rank, worldSize: collective.size, transport: collective.transport)
            let identity = configuration.identity
            // Rank, local path and local uptime deadline are deliberately absent
            // from this cross-host digest; ordered membership/builds are common.
            let common = sha256(try canonicalJSONData([
                "qwen-resident-load-v1", identity.membershipEpoch.uuidString.lowercased(), identity.modelID,
                identity.configurationSHA256, identity.artifactSHA256, admission.specification.manifestSHA256,
                admission.plan.fingerprint, admission.profile.fingerprint, admission.arithmeticSHA256,
                admission.jaccl.fingerprint,
            ] + identity.peers.flatMap { [$0.id, $0.buildSHA256] }))
            let capacity = try MLX.withError { nativeError in
                func checked() throws { try nativeError.check(); try control.check(); try nativeError.check() }
                do {
                    _ = try requireQwenLongPrefillReadinessDigest(collective: collective,
                        material: { .residentLoadIntent(agreementFingerprint: common) },
                        disagreementMessage: "Resident load membership/source/Plan differs", check: checked)
                    try autoreleasepool {
                        let value = try loadQwenResidentStage(admission, check: checked)
                        retired = value.loaded.model; stage = value
                    }
                    guard let loaded = stage else { throw ProbeError("Resident loader returned no stage") }
                    let maximum = try QwenResidentRequestAllowance.derive(profile: loaded.profile, plan: admission.plan,
                        rank: collective.rank, maximumTokens: admission.profile.maximumContextTokens,
                        chunkSize: admission.profile.maximumChunkTokens, bound: QwenResidentResourceEnvironment.allocationBound)
                    try maximum.requireLive(); try checked()
                    let loadedIdentity = sha256(try canonicalJSONData([common,
                        loaded.loaded.receipt.storageCommitmentSHA256, loaded.loaded.receipt.sourceParameterLayoutSHA256]))
                    _ = try requireQwenLongPrefillReadinessDigest(collective: collective,
                        material: { .residentLoaded(agreementFingerprint: loadedIdentity) },
                        disagreementMessage: "Resident peers did not load matching verified stage commitments", check: checked)
                    try checked()
                    return maximum.reservedBytes
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
                stage: stage!, capacity: capacity, lifecycle: lifecycle)
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
