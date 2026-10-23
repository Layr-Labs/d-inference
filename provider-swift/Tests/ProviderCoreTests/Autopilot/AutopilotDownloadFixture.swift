import Foundation
@testable import ProviderCore

/// A provider over a temporary model cache and config folder. Builds are
/// written in the Hugging Face layout the real scanner reads, like finished
/// downloads, and the loop's Autopilot downloads run a scripted prefetcher.
/// The model cache folder is process-wide (`ModelScanner.configureCacheDirectory`):
/// suites using this fixture are serialized and runs use `--no-parallel`.
final class AutopilotDownloadFixture: @unchecked Sendable {
    static let saved = "darkbloom-test/saved-model"
    static let revision = "download-test"

    let root: URL
    let cache: URL
    let configPath: URL
    let loop: ProviderLoop
    private let previousCache: String?

    private init(root: URL, cache: URL, configPath: URL, loop: ProviderLoop, previousCache: String?) {
        self.root = root
        self.cache = cache
        self.configPath = configPath
        self.loop = loop
        self.previousCache = previousCache
    }

    static func make(consent: Bool = true, paused: Bool = false, privateOnly: Bool = false,
                     selected: [String] = [saved], inventory: [ModelInfo] = [], ordinary: [ModelInfo] = [],
                     downloads: AutopilotDownloadSettings? = .init(enabled: true)) async throws -> AutopilotDownloadFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("autopilot-download-\(UUID().uuidString)", isDirectory: true)
        let cache = root.appendingPathComponent("hub", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let previous = ModelScanner.configuredCacheDirectory
        ModelScanner.configureCacheDirectory(cache.path)
        let settings = ModelAutopilotSettings(enabled: consent, consentRecorded: consent, paused: paused,
            selectedModels: selected, revision: revision, minIdleSeconds: 1)
        let configPath = root.appendingPathComponent("provider.toml")
        let loop = try ProviderLoop(
            config: ProviderLoopConfig(
                coordinatorURL: "ws://127.0.0.1:0/unused", hardware: ModelLoadingFixtures.defaultHardware,
                models: ordinary,
                config: ProviderConfig(
                    provider: ProviderSettings(name: "autopilot-download-test", memoryReserveGB: 0),
                    backend: BackendSettings(idleTimeoutMins: 60, maxModelSlots: 4, mtpMode: .off,
                        modelAutopilot: settings, autopilotDownloads: downloads),
                    coordinator: CoordinatorSettings(heartbeatIntervalSecs: 60, privateOnly: privateOnly)),
                modelHashes: Dictionary((inventory + ordinary).compactMap { m in m.weightHash.map { (m.id, $0) } },
                    uniquingKeysWith: { first, _ in first }),
                configPath: configPath,
                autopilotInventory: inventory),
            attestationSigner: nil,
            kvBudgetForTesting: ScriptedProviderMemory.budget(modelIDs: (inventory + ordinary).map(\.id)))
        await loop.setDaemonStateFileForTesting(root.appendingPathComponent("daemon-state.json"))
        await loop.setLoadedModelsPersistenceEnabledForTesting(false)
        await loop.setEngineV2RuntimeForTesting(EngineV2Runtime())
        await loop.publishModelAutopilotSnapshot()
        return AutopilotDownloadFixture(root: root, cache: cache, configPath: configPath, loop: loop,
            previousCache: previous)
    }

    /// A finished download of `id`: a config naming its engine family and
    /// a few bytes of weights.
    @discardableResult
    func writeBuild(_ id: String, modelType: String = "gpt_oss", byte: UInt8 = 0x5a) throws -> URL {
        let folder = cache.appendingPathComponent(ModelScanner.cacheDirectoryName(for: id), isDirectory: true)
        let snapshot = folder.appendingPathComponent("snapshots/rev-1", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("refs"), withIntermediateDirectories: true)
        try Data("rev-1".utf8).write(to: folder.appendingPathComponent("refs/main"))
        try Data(#"{"model_type":"\#(modelType)"}"#.utf8).write(to: snapshot.appendingPathComponent("config.json"))
        try Data(repeating: byte, count: 512).write(to: snapshot.appendingPathComponent("model.safetensors"))
        return snapshot
    }

    func removeBuild(_ id: String) throws {
        try FileManager.default.removeItem(at: cache.appendingPathComponent(ModelScanner.cacheDirectoryName(for: id)))
    }

    /// The scanned build with its weight hash, as the start path records it.
    func scannedBuild(_ id: String) -> ModelInfo? {
        guard let snapshot = ModelScanner.resolveLocalPath(modelID: id),
              var info = ModelScanner.parseModelInfo(snapshotDir: snapshot, modelName: id) else { return nil }
        info.weightHash = WeightHasher.computeHash(snapshotDir: snapshot, modelID: id)
        return info
    }

    func installDownloads(_ body: @escaping @Sendable (String) async throws -> Void) async -> DownloadLog {
        let log = DownloadLog()
        let coordinator = await loop.makeAutopilotDownloadCoordinator(prefetcher: ScriptedDownload { id in
            log.started(id)
            try await body(id)
        })
        await loop.installAutopilotDownloadCoordinatorForTesting(coordinator)
        return log
    }

    var ledger: AutopilotDownloadLedger {
        AutopilotDownloadLedger.read(from: AutopilotDownloadLedger.url(configDirectory: root))
    }

    /// `darkbloom autopilot disable` as the running provider sees it: the
    /// saved config changes and the next policy refresh reads it.
    func revokeConsent() async throws {
        var config = await loop.loopConfig.config
        config.backend.modelAutopilot.consentRecorded = false
        config.backend.modelAutopilot.enabled = false
        try ConfigManager.save(config, to: configPath)
        await loop.refreshAutopilotSettings()
    }

    /// Synchronous, so the process-wide model cache folder is restored
    /// before the next test configures its own.
    func release() {
        ModelScanner.configureCacheDirectory(previousCache)
        try? FileManager.default.removeItem(at: root)
        let loop = self.loop
        Task { await loop.idleMonitorTask?.cancel() }
    }
}

struct ScriptedDownload: ModelPrefetcher {
    let body: @Sendable (String) async throws -> Void
    func prefetchToDisk(modelID: String, onByteProgress: @Sendable @escaping (Int64, Int64) -> Void) async throws {
        try await body(modelID)
        onByteProgress(512, 512)
    }
}

final class DownloadLog: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [String] = []
    func started(_ id: String) { lock.withLock { ids.append(id) } }
    var started: [String] { lock.withLock { ids } }
}

/// Whether a registered connection exists, and every reconnect request.
final class ReconnectLog: @unchecked Sendable {
    private let lock = NSLock()
    private var isRegistered = false
    private var accepts: Bool
    private var count = 0
    init(accept: Bool) { accepts = accept }
    var registered: Bool {
        get { lock.withLock { isRegistered } }
        set { lock.withLock { isRegistered = newValue } }
    }
    var accept: Bool {
        get { lock.withLock { accepts } }
        set { lock.withLock { accepts = newValue } }
    }
    var requests: Int { lock.withLock { count } }
    func request() -> Bool { lock.withLock { count += 1; return accepts } }
}

/// Outbound messages other than prefetch replies.
final class OutboundLog: @unchecked Sendable {
    private let lock = NSLock()
    private var updates = 0
    func append(_ message: OutboundMessage) {
        if case .modelsUpdate = message { lock.withLock { updates += 1 } }
    }
    var modelsUpdates: Int { lock.withLock { updates } }
}

/// `prefetch_model_status` replies, in order.
final class PrefetchReplies: @unchecked Sendable {
    struct Reply: Equatable {
        let status: ProviderMessage.PrefetchModelStatus.Status
        let error: String?
    }
    private let lock = NSLock()
    private var replies: [Reply] = []
    func append(_ message: OutboundMessage) {
        guard case .prefetchModelStatus(_, let status, _, _, let error) = message else { return }
        lock.withLock { replies.append(.init(status: status, error: error)) }
    }
    var all: [Reply] { lock.withLock { replies } }
    var statuses: [ProviderMessage.PrefetchModelStatus.Status] { all.map(\.status) }
    var terminal: Reply? { all.last { $0.status == .verified || $0.status == .failed } }
}

extension ProviderLoop {
    func installAutopilotDownloadCoordinatorForTesting(_ coordinator: ModelPrefetchCoordinator) {
        autopilotDownloadCoordinator = coordinator
    }

    func setAutopilotRegistrationSeamForTesting(_ log: ReconnectLog) {
        autopilotRegistrationSeamForTesting = (registered: { log.registered }, reconnect: { log.request() })
    }

    func setOutboundSendForTesting(_ send: SendHandle) { outboundSend = send }

    /// A self-test failed on `hash` ("" refuses every build of the ID).
    func recordFailedSelfTestForTesting(_ id: String, hash: String) { failedSelfTestHashes[id] = hash }
    func failedSelfTestHashForTesting(_ id: String) -> String? { failedSelfTestHashes[id] }

    /// Sends the request and waits for its terminal reply.
    func prefetchForTesting(_ id: String) async -> PrefetchReplies {
        let replies = PrefetchReplies()
        await handlePrefetchModelRequest(modelId: id, priority: 0, send: SendHandle(replies.append))
        _ = await modelLoadingWaitUntil { replies.terminal != nil }
        return replies
    }
}
