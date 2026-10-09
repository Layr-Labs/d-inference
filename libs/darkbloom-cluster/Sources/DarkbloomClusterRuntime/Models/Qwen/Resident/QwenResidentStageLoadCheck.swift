import DarkbloomClusterProtocol
import Foundation
import MLX
import MLXNN

/// Loads one rank's verified stage from the registered artifact on this Mac and
/// releases it again, without creating a collective. It qualifies the artifact,
/// the loader and local memory release for that rank. It is not a membership,
/// transport or generation result, and the peer's stage is only inspected.
public enum QwenResidentStageLoadCheck {
    public struct Receipt: Encodable, Sendable {
        public let schema = "qwen_resident_stage_load_check_v1"
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
        public let loadSeconds: Double
        /// How long the loaded stage was kept before its release (0 unless asked).
        public let heldSeconds: Double
        /// What the host memory gate decided during this load.
        public let resourceAdmission: QwenDenseStageLoadAdmissionSummary
        public let collectiveCreated = false
    }

    /// The device matrix is the only synthetic input: admission parses one, and
    /// no collective opens it. The arithmetic environment must be the actual
    /// process environment, because MLX reads those values itself.
    private static let matrixPath = "/var/empty/darkbloom-stage-load-check.matrix.json"
    private static let matrix = Data(#"[[null,"stage-load-check-0"],["stage-load-check-1",null]]"#.utf8)
    private static let nativeNames = ["JACCL_RANK", "MLX_RANK", "JACCL_IBV_DEVICES", "MLX_IBV_DEVICES",
        "JACCL_COORDINATOR", "MLX_JACCL_COORDINATOR", "JACCL_RING", "MLX_JACCL_RING"]

    /// `holdSeconds` keeps the loaded stage for that long before releasing it,
    /// so a second load can be tried on the same Mac while this one is resident.
    public static func run(modelDirectory: URL, rank: Int, stageCut: Int,
                           deadlineUptimeNanoseconds: UInt64, holdSeconds: Int = 0) throws -> Receipt {
        guard (0...240).contains(holdSeconds) else { throw ProbeError("Stage load check holds for 0...240 seconds") }
        var environment = ProcessInfo.processInfo.environment
        guard nativeNames.allSatisfy({ environment[$0] == nil }) else {
            throw ProbeError("Stage load check refuses a cluster transport environment; it creates no collective")
        }
        environment["JACCL_RANK"] = String(rank)
        environment["JACCL_IBV_DEVICES"] = matrixPath
        environment["JACCL_COORDINATOR"] = "127.0.0.1:1"
        // The artifact's own configuration selects the registered model. Bytes
        // that belong to no registered model have no definition and stop here.
        let configBytes = try BoundedProbeInput.data(modelDirectory.appendingPathComponent("config.json"),
                                                    maximumBytes: 1_048_576)
        let specification = try QwenResidentModelDefinition(configuration: configBytes).specification
        let identity = ClusterWorkerIdentity(membershipEpoch: UUID(),
            modelID: specification.model.rawValue,
            artifactSHA256: specification.artifactSHA256,
            configurationSHA256: specification.configurationSHA256,
            peers: (0...1).map {
                ClusterWorkerPeer(id: "stage-load-check-\($0)", buildSHA256: String(repeating: "0", count: 64))
            })
        let configuration = QwenResidentLoadConfiguration(identity: identity, modelDirectory: modelDirectory,
            rank: rank, stageCut: stageCut, deadlineUptimeNanoseconds: deadlineUptimeNanoseconds)
        let admission = try QwenResidentAdmission(configuration: configuration,
            configBytes: configBytes,
            manifestBytes: BoundedProbeInput.data(modelDirectory.appendingPathComponent("manifest.json"),
                                                  maximumBytes: 4_194_304),
            environment: environment, now: DispatchTime.now().uptimeNanoseconds,
            read: { url, limit in
                url.path == matrixPath ? matrix : try BoundedProbeInput.data(url, maximumBytes: limit)
            })
        let control = QwenResidentControl(deadline: deadlineUptimeNanoseconds)
        try QwenResidentProcessLease.shared.acquire()
        defer { QwenResidentProcessLease.shared.release() }
        try control.check()
        try QwenResidentResourceEnvironment.require()

        var stage: QwenResidentLoadedStage?
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
                try autoreleasepool {
                    let value = try loadQwenResidentStage(admission, check: checked)
                    retired = value.loaded.model; stage = value
                }
                try settle()
                let seconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9
                let loadedBytes = Memory.snapshot().activeMemory
                // Copy out plain values only: a second reference to the stage
                // here would keep the model alive past the release below.
                guard let receipt = stage?.loaded.receipt, let layers = stage?.loaded.layerCount else {
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
                return Receipt(rank: rank, stageCut: stageCut, layerCount: layers,
                    verifiedAggregateSHA256: receipt.verifiedAggregateSHA256,
                    storageCommitmentSHA256: receipt.storageCommitmentSHA256,
                    sourceParameterLayoutSHA256: receipt.sourceParameterLayoutSHA256,
                    loadedTensorBytes: receipt.loadedTensorBytes,
                    activeBytesBefore: before, activeBytesLoaded: loadedBytes,
                    activeBytesAfterRelease: after.activeMemory, cacheBytesAfterRelease: after.cacheMemory,
                    modelReleased: retired == nil, loadSeconds: seconds, heldSeconds: holdSeconds == 0 ? 0 : held,
                    resourceAdmission: .current)
            } catch {
                let primary = error
                stage = nil
                Stream.gpu.synchronize(); Stream.cpu.synchronize()
                Memory.clearCache()
                // Prefer a recorded native fault over a secondary Swift error.
                try nativeError.check()
                throw primary
            }
        }
    }
}
