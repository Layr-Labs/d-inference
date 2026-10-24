import CryptoKit
import Darwin
import Foundation
import ProviderAppAttest

/// Opt-in physical qualification of the shipped serving loop, not a substitute
/// transport or engine. No caller can supply key material, status claims or hashes.
public enum NativeServeQualification {
    public static let environmentKey = "DARKBLOOM_NATIVE_SERVE_QUALIFICATION"

    public static func run(coordinatorURL: String, directory: String) async throws {
        guard ProcessInfo.processInfo.environment[environmentKey] == "1" else {
            throw NativeServeQualificationInputs.Failure.optInRequired
        }
        let inputs = try NativeServeQualificationInputs(coordinatorURL: coordinatorURL, path: directory)
        let workerQualification = try NativeWorkerServeQualification.selected()
        umask(0o077)
        setenv("TMPDIR", inputs.directory.path, 1)
        guard let binaryHash = selfBinaryHash(), let process = ProcessIdentity.current() else {
            throw NativeServeQualificationInputs.Failure.signedReleaseRequired
        }
        _ = try SignedReleaseIdentity.verifyCurrent(expectedBinarySHA256: binaryHash, expectedVersion: ProviderCore.version)
        // Check DeviceCheck's real availability before allocating a model. This
        // does not generate a credential or ask Apple for a proof.
        let apple = AppleAppAttestService()
        try await apple.checkAvailability(environment: "production")

        let stateDirectory = inputs.directory.appendingPathComponent("state", isDirectory: true)
        guard mkdir(stateDirectory.path, 0o700) == 0 else { throw NativeServeQualificationInputs.Failure.privateDirectoryRequired }
        let paths = ["DARKBLOOM_PID_FILE": "provider.pid", "DARKBLOOM_STATE_FILE": "provider-state.json",
                     "DARKBLOOM_LOADED_MODELS_FILE": "loaded-models.json", "DARKBLOOM_WATCHDOG_STATE": "watchdog.json",
                     "DARKBLOOM_KV_BACKEND_GUARD": "kv-guard.json",
                     "DARKBLOOM_VERIFIED_WEIGHTS_FILE": "verified-weights.json"]
        for (key, name) in paths { setenv(key, stateDirectory.appendingPathComponent(name).path, 1) }
        // No SSD keychain/maintenance or update installation belongs to this
        // diagnostic. These are normal operator settings, not privacy claims.
        setenv("DARKBLOOM_PREFIX_CACHE", "0", 1)
        setenv("DARKBLOOM_PREFIX_CACHE_MEMORY", "0", 1)
        setenv("DARKBLOOM_NO_UPDATE_CHECK", "1", 1)
        ModelScanner.configureCacheDirectory(inputs.modelCache.path)
        let hardware = try HardwareDetector.detect()
        let capabilities = ProviderRuntimeCapabilityDetector.detectLive(hardware: hardware)
        let models = ModelScanner.scanModels(in: inputs.modelCache, availableMemoryGB: hardware.memoryAvailableGb)
        guard let model = models.first(where: { $0.id == inputs.modelID }),
              ModelRuntimeRequirements.isEligible(modelID: model.id, available: capabilities),
              EngineV2SupportedModels.isSupported(model: model), model.templateRenderOK == true
        else { throw NativeServeQualificationInputs.Failure.modelUnavailable }
        var config = ProviderConfig(provider: ProviderSettings(name: "native-qualification"))
        config.coordinator.url = inputs.coordinatorURL
        config.coordinator.heartbeatIntervalSecs = 5
        config.provider.autoUpdate = false
        config.provider.autoRestart = false
        config.backend.modelCacheDirectory = inputs.modelCache.path
        config.backend.enabledModels = [model.id]
        config.backend.preloadModels = [model.id]
        config.backend.maxModelSlots = 1
        config.backend.engineV2MaxConcurrent = 1
        config.backend.engineV2KVBackend = "contiguous"
        config.backend.mtpMode = .off
        config.backend.startupSelftestFailClosed = true
        let loads = NativeServeLoadCounter()
        let loop = try ProviderLoop(config: ProviderLoopConfig(
            coordinatorURL: inputs.coordinatorURL, hardware: hardware, models: [model], config: config,
            authToken: inputs.token, runtimeCapabilities: capabilities),
            attestationSigner: SecureEnclaveIdentity(), beforeModelLoad: { _ in loads.increment() })
        await loop.prepareNativeQualification(inputs: inputs, stateDirectory: stateDirectory, apple: apple,
            workerQualification: workerQualification)
        await ProviderTermination.shared.install { await loop.drainAndShutdown(timeoutSeconds: 20) }
        try await NativeServeRunLifetime.run(serve: { try await loop.run() }, observe: {
            let deadline = ContinuousClock.now + .seconds(900)
            var sequence: UInt64 = 0
            while true {
                try Task.checkCancellation()
                sequence += 1
                try await loop.armNativeWorkerQualificationIfRequested(inputs)
                try await loop.writeNativeQualificationObservation(to: inputs.directory, process: process,
                    loads: loads.value, sequence: sequence)
                if inputs.finished() { return }
                if ContinuousClock.now >= deadline {
                    throw NativeServeQualificationInputs.Failure.deadlineExceeded
                }
                try await Task.sleep(for: .milliseconds(250))
            }
        }, shutdown: {
            guard await loop.drainAndShutdown(timeoutSeconds: 20) else {
                throw NativeServeQualificationInputs.Failure.shutdownIncomplete
            }
        })
    }
}

private final class NativeServeLoadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

/// Keeps Apple's real key identifier and its generation budget for this process
/// only. Losing the process cannot leave an enrollment record in operator storage.
final class NativeServeKeyStorage: ShadowKeyStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [String: ShadowKeyRecord] = [:]
    func load(scope: String) throws -> ShadowKeyRecord? { lock.withLock { records[scope] } }
    func save(_ record: ShadowKeyRecord, scope: String) throws {
        try lock.withLock {
            guard records[scope] != nil || records.count < 8 else { throw NativeServeQualificationInputs.Failure.invalidInput }
            records[scope] = record
        }
    }
}

private extension ProviderLoop {
    func prepareNativeQualification(inputs: NativeServeQualificationInputs, stateDirectory: URL, apple: AppleAppAttestService,
                                    workerQualification: NativeWorkerServeQualification?) {
        daemonStateFileOverride = stateDirectory.appendingPathComponent("provider-state.json")
        loadedModelsFileOverride = stateDirectory.appendingPathComponent("loaded-models.json")
        serveUsesHostServices = false
        startMemoryProtection(markerURL: stateDirectory.appendingPathComponent("oom-marker.json"),
            lastScanURL: stateDirectory.appendingPathComponent("oom-last-scan"), diagnosticReportsDirs: [])
        specDecFunnel = SpecDecArtifactFunnel(
            resolver: SpecDecResolver(storeRoot: stateDirectory.appendingPathComponent("spec-dec"),
                                      cdnBaseURL: inputs.coordinatorURL.replacingOccurrences(of: "ws://", with: "http://")),
            catalog: SpecDecCatalogLookup(coordinatorURL: inputs.coordinatorURL))
        nativeWorkerQualification = workerQualification
        if !usesAppAttestWorker {
            appAttestShadowClient = AppAttestShadowClient(scope: inputs.coordinatorURL,
                service: apple, storage: NativeServeKeyStorage())
        }
    }

    func writeNativeQualificationObservation(to directory: URL, process: ProcessIdentity, loads: Int, sequence: UInt64) throws {
        let slots = modelSlots.values.map { slot in
            ["model_instance": nativeDigest(Data("\(process.startTimeMicros):\(slot.modelContainer.identity)".utf8)),
             "engine_instance": nativeDigest(Data(slot.engineBundle.instanceID.uuidString.utf8))]
        }
        var observation: [String: Any] = [
            "pid": process.pid, "process_start_micros": process.startTimeMicros,
            "sequence": sequence, "captured_at_ns": UInt64(Date().timeIntervalSince1970 * 1_000_000_000),
            "uptime_ns": UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000_000),
            "endpoint_sha256": nativeDigest(keyPair.publicKeyBytes),
            "load_count": loads, "loaded_models": modelSlots.count,
            "inflight": lifecycleRemaining, "slots": slots,
        ]
        if let nativeWorkerQualification {
            observation["worker_fault"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(nativeWorkerQualification.snapshot))
        }
        try OwnerOnlyFile.write(JSONSerialization.data(withJSONObject: observation, options: [.sortedKeys]),
                                to: directory.appendingPathComponent("observation.json"))
    }
}

private func nativeDigest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
