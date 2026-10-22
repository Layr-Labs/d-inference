import Foundation
import MLX
@_spi(Cluster) import MLXLLM
import MLXNN

/// Benchmark-only loading check. The enclosing executable must hold the shared
/// cross-process device exclusion and enforce a hard lifetime. No Collective,
/// session, token forward or request-history object is constructed here.
@_spi(Benchmark) public enum QwenResidentMTPLoadCheck {
    public static func run(configuration: QwenResidentLoadConfiguration,
        onAdmitted: (Data) throws -> Void
    ) throws -> Data {
        guard configuration.rank == 1, configuration.stageCut == 4,
              configuration.prefillSchedule == .serial,
              configuration.allocatorPolicy == .disableFreedBufferCache else {
            throw ProbeError("MTP selected-load check requires final rank1/cut4, serial and dedicated cache-off")
        }
        let control = QwenResidentControl(deadline: configuration.deadlineUptimeNanoseconds)
        try control.check()
        try QwenResidentResourceEnvironment.require()
        let initial = try QwenDenseStageLoadResources.requireInitial()
        let directory = configuration.modelDirectory
        let admission = try QwenResidentAdmission(configuration: configuration,
            configBytes: BoundedProbeInput.data(directory.appendingPathComponent("config.json"), maximumBytes: 1_048_576),
            manifestBytes: BoundedProbeInput.data(directory.appendingPathComponent("manifest.json"), maximumBytes: 4_194_304),
            environment: ProcessInfo.processInfo.environment, now: DispatchTime.now().uptimeNanoseconds,
            read: { try BoundedProbeInput.data($0, maximumBytes: $1) })
        let admitted = QwenResidentMTPLoadCheckAdmission(admission, initial: initial)
        try control.check()
        try QwenResidentProcessLease.shared.acquire()
        // A failure keeps process admission closed. The dedicated process must
        // exit and its external owner must fence it, even after local cleanup.
        weak var retiredFiles: VerifiedCheckpoint?
        weak var retiredTarget: Module?
        weak var retiredAssistant: Qwen35InlineMTPAssistant?
        let output = try QwenResidentMTPLoadPublication.run(body: {
            try onAdmitted(try encode(admitted))
            try control.check()
            return try MLX.withError { nativeError in
                func checked() throws { try nativeError.check(); try control.check(); try nativeError.check() }
                do {
                    try admission.jaccl.requireUnchanged(environment: ProcessInfo.processInfo.environment,
                        read: { try BoundedProbeInput.data($0, maximumBytes: $1) })
                    try QwenResidentResourceEnvironment.require(); try checked()
                    try configuration.allocatorPolicy.configure(setCacheLimit: { Memory.cacheLimit = $0 }, check: checked)
                    let before = QwenStageMemoryObservation("before_selected_mtp_load")
                    let runtime = QwenDenseStageLoadRuntimeObservation()
                    let payload = try autoreleasepool {
                        let source = try PreparedQwenResidentMTPSource(admission: admission, check: checked)
                        retiredFiles = source.target.source.prepared.checkpoint
                        let value = try materializePreparedQwenResidentMTPAssets(admission, source: source, check: checked)
                        retiredTarget = value.target.loaded.model; retiredAssistant = value.assistant
                        try configuration.allocatorPolicy.prepareReady(
                            synchronize: { Stream.gpu.synchronize(); Stream.cpu.synchronize() },
                            snapshot: { .init(activeBytes: Memory.activeMemory, cachedBytes: Memory.cacheMemory,
                                              peakBytes: Memory.peakMemory) },
                            clearCache: { Memory.clearCache() }, check: checked)
                        try QwenResidentResourceEnvironment.require(); try checked()
                        let os = try QwenDenseStageLoadResources.requireInitial()
                        try admission.jaccl.requireUnchanged(environment: ProcessInfo.processInfo.environment,
                            read: { try BoundedProbeInput.data($0, maximumBytes: $1) })
                        try checked()
                        return QwenResidentMTPLoadCheckPayload(targetLoad: value.target.loaded.receipt,
                            mtpLoad: value.receipt, loadedResources: os,
                            loadedMemory: QwenStageMemoryObservation("selected_mtp_loaded"))
                    }
                    try checked()
                    return (payload, before, runtime)
                } catch { try nativeError.check(); throw error }
            }
        }, retire: {
            // Cleanup never depends on the now possibly expired deadline or a
            // failing resource screen. It uses a fresh native-error scope.
            try MLX.withError { nativeError in
                Stream.gpu.synchronize(); Stream.cpu.synchronize(); try nativeError.check()
                Memory.clearCache(); try nativeError.check()
                guard retiredTarget == nil, retiredAssistant == nil, retiredFiles == nil,
                      Memory.cacheMemory == 0 else {
                    throw ProbeError("MTP selected load retained a native owner, verified files or cached buffers")
                }
            }
        }, prepare: { result in
            let (payload, before, runtime) = result
            try control.check(); try QwenResidentResourceEnvironment.require()
            let released = try QwenDenseStageLoadResources.requireInitial()
            let report = QwenResidentMTPLoadCheckReport(admission: admitted, payload: payload,
                initialMemory: before, releasedMemory: QwenStageMemoryObservation("selected_mtp_released"),
                releasedResources: released, runtime: runtime)
            let bytes = try encode(report)
            try control.check()
            return bytes
        })
        QwenResidentProcessLease.shared.release()
        return output
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let bytes = try canonicalJSONData(value)
        guard !bytes.isEmpty, bytes.count <= 8_388_608 else {
            throw ProbeError("MTP selected-load CPU record exceeds 8 MiB")
        }
        return bytes
    }
}
