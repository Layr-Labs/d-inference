import DarkbloomClusterProtocol
import Foundation
import MLX
import MLXNN

/// Loads one rank's verified GPT-OSS stage from the registered artifact on
/// this Mac and releases it again, without creating a collective. It qualifies
/// the artifact, the loader and local memory release for that rank. It is not
/// a membership, transport or generation result, and the peer's stage is only
/// inspected.
public enum GPTOSSResidentStageLoadCheck {
    public struct Receipt: Encodable, Sendable {
        public let schema = "gpt_oss_resident_stage_load_check_v1"
        public let runtimeModelID: String
        public let rank: Int
        public let stageCut: Int
        public let layerCount: Int
        public let verifiedAggregateSHA256: String
        public let storageCommitmentSHA256: String
        public let sourceParameterLayoutSHA256: String
        public let loadedTensorBytes: Int
        public let activeBytesBefore: Int
        public let activeBytesLoaded: Int
        public let activeBytesAfterRelease: Int
        public let cacheBytesAfterRelease: Int
        public let modelReleased: Bool
        /// Hashing every manifest file and reading the tensor headers.
        public let verifySeconds: Double
        /// Constructing the stage and reading its tensors.
        public let loadSeconds: Double
        /// How long the loaded stage was kept before its release (0 unless asked).
        public let heldSeconds: Double
        /// What the host memory gate decided for this load.
        public let resourceAdmission: QwenResidentResourceAdmissionReport
        public let collectiveCreated = false
    }

    public static func handles(configuration: Data) -> Bool {
        GPTOSSRegisteredSpecification.handles(configuration: configuration)
    }

    /// `holdSeconds` keeps the loaded stage for that long before releasing it,
    /// so a second load can be tried on the same Mac while this one is resident.
    public static func run(modelDirectory: URL, rank: Int, stageCut: Int,
                           deadlineUptimeNanoseconds: UInt64, holdSeconds: Int = 0) throws -> Receipt {
        guard (0...240).contains(holdSeconds) else { throw ProbeError("Stage load check holds for 0...240 seconds") }
        let admission = try GPTOSSResidentAdmission.local(modelDirectory: modelDirectory, rank: rank,
            stageCut: stageCut, deadlineUptimeNanoseconds: deadlineUptimeNanoseconds, label: "stage-load-check")
        let control = QwenResidentControl(deadline: deadlineUptimeNanoseconds)
        try QwenResidentProcessLease.shared.acquire()
        defer { QwenResidentProcessLease.shared.release() }
        try control.check()
        try QwenResidentResourceEnvironment.require()

        var stage: LoadedGPTOSSLayerStage?
        weak var retired: Module?
        return try MLX.withError { nativeError in
            func checked() throws { try nativeError.check(); try control.check(); try nativeError.check() }
            func settle() throws {
                Stream.gpu.synchronize(); Stream.cpu.synchronize()
                try nativeError.check()
            }
            do {
                try settle()
                let before = Memory.snapshot().activeMemory
                let started = DispatchTime.now().uptimeNanoseconds
                var verified = started
                try autoreleasepool {
                    let source = try prepareGPTOSSResidentSource(directory: modelDirectory,
                        configuration: admission.configBytes, manifest: admission.manifestBytes,
                        specification: admission.specification, plan: admission.plan, check: checked)
                    verified = DispatchTime.now().uptimeNanoseconds
                    // The weak reference is set when the model is built, so it
                    // also answers for a load that fails part-way.
                    stage = try loadGPTOSSResidentStage(source: source, stageIndex: rank, check: checked,
                                                        constructed: { retired = $0 })
                }
                try settle()
                let finished = DispatchTime.now().uptimeNanoseconds
                let loadedBytes = Memory.snapshot().activeMemory
                // Copy out plain values only: a second reference to the stage
                // here would keep the model alive past the release below.
                guard let receipt = stage?.receipt, let layers = stage?.layerCount else {
                    throw ProbeError("Stage loader returned no stage")
                }
                let holdStarted = DispatchTime.now().uptimeNanoseconds
                let holdUntil = holdStarted + UInt64(holdSeconds) * 1_000_000_000
                while DispatchTime.now().uptimeNanoseconds < holdUntil {
                    try checked()
                    Thread.sleep(forTimeInterval: 0.1)
                }
                let held = Double(DispatchTime.now().uptimeNanoseconds - holdStarted) / 1e9
                // Release in the order the resident runtime uses: drop the
                // stage, drain both streams, then return cached buffers.
                stage = nil
                try settle()
                Memory.clearCache()
                try settle()
                let after = Memory.snapshot()
                return Receipt(runtimeModelID: admission.specification.model.rawValue, rank: rank, stageCut: stageCut,
                    layerCount: layers, verifiedAggregateSHA256: receipt.verifiedAggregateSHA256,
                    storageCommitmentSHA256: receipt.storageCommitmentSHA256,
                    sourceParameterLayoutSHA256: receipt.sourceParameterLayoutSHA256,
                    loadedTensorBytes: receipt.loadedTensorBytes,
                    activeBytesBefore: before, activeBytesLoaded: loadedBytes,
                    activeBytesAfterRelease: after.activeMemory, cacheBytesAfterRelease: after.cacheMemory,
                    modelReleased: retired == nil, verifySeconds: Double(verified - started) / 1e9,
                    loadSeconds: Double(finished - verified) / 1e9, heldSeconds: holdSeconds == 0 ? 0 : held,
                    resourceAdmission: .current)
            } catch {
                var primary: Error = error
                stage = nil
                Stream.gpu.synchronize(); Stream.cpu.synchronize()
                Memory.clearCache()
                // Prefer a recorded native fault over a secondary Swift error.
                do { try nativeError.check() } catch { primary = error }
                // What this process still holds after releasing a failed load.
                let after = Memory.snapshot()
                throw QwenResidentReleasedFailure(failure: String(describing: primary),
                    activeBytesAfterRelease: after.activeMemory, cacheBytesAfterRelease: after.cacheMemory,
                    modelsReleased: [retired == nil], resourceAdmission: .current)
            }
        }
    }
}
