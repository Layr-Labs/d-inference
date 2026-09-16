import Foundation
import MLX
import MLXLMCommon

/// Offline measurement access to a real production slot. Raw events preserve
/// token IDs; HTTP framing and bridge admission timing are intentionally absent.
@_spi(Benchmarking)
public actor EngineV2BenchmarkSession {
    public struct Submission: Sendable {
        public let receiptID: CBv2RequestID
        public let events: AsyncStream<CBv2Event>
        public let stageMilliseconds: Double
        public let stageDisposition: String
    }

    public struct CacheSnapshot: Sendable {
        public let durableMode: String?
        public let keyMode: String?
        public let status: PrefixCacheModelStatus
        public let memoryEnabled: Bool
        public let recurrentBankBudgetBytes: Int
        public let engineKVCapacityBytes: Int
        public let physicalMemoryBytes: UInt64
        public let activationReserveBytes: UInt64
        public let postLoadMaximumKVBytes: UInt64
        public let checkpoints: SSDHybridCheckpointStats?
        public let attention: SSDPrefixCacheStats?
        public let processMemory: ProcessMemoryTelemetry?
        public let assistantIdentity: [String: String]
        public let productionGrant: EngineV2BenchmarkProductionGrant?
        public let postBuildHeadroomBytes: UInt64?
    }

    public enum Failure: Error {
        case invalidVerifiedWeightHash, invalidCapacity, mtpUnavailable
        case unexpectedEngine, unexpectedResidentCache, persistentKeyUnavailable
        case ssdUnavailable(status: PrefixCacheModelStatus, hasEvidenceSource: Bool)
        case unservablePostLoad(headroomBytes: UInt64, requiredBytes: UInt64)
        case closed, requestAlreadyActive, receiptIDsExhausted
    }

    /// Metric/cancellation access, plus explicit teacher forcing on an idle,
    /// cache-disabled diagnostic session. Submit ordinary requests through this
    /// session so checkpoint receipt and staging lifetimes remain paired.
    public nonisolated let rawEngine: EngineV2
    public nonisolated let backend: String
    public nonisolated let backendFallback: String?
    private let bundle: ProviderEngineBundle
    private let budget: GlobalKVCacheBudget
    private let assistantIdentity: [String: String]
    private var memorySampler = ProcessMemoryTelemetrySampler()
    private let memoryEnabled: Bool
    private let activationReserveBytes: UInt64
    private let postLoadMaximumKVBytes: UInt64
    private let productionGrant: EngineV2BenchmarkProductionGrant?
    private let postBuildHeadroomBytes: UInt64?
    private var nextReceipt: UInt64 = 1
    private var active: [CBv2RequestID: CBv2RequestID] = [:]
    private var closed = false

    init(
        bundle: ProviderEngineBundle, engine: EngineV2,
        backend: String, fallback: String?, memoryEnabled: Bool,
        activationReserveBytes: UInt64, postLoadMaximumKVBytes: UInt64,
        budget: GlobalKVCacheBudget, assistantIdentity: [String: String],
        productionGrant: EngineV2BenchmarkProductionGrant?, postBuildHeadroomBytes: UInt64?
    ) {
        self.bundle = bundle
        self.budget = budget
        self.assistantIdentity = assistantIdentity
        self.productionGrant = productionGrant
        self.postBuildHeadroomBytes = postBuildHeadroomBytes
        self.rawEngine = engine
        self.backend = backend
        self.backendFallback = fallback
        self.memoryEnabled = memoryEnabled
        self.activationReserveBytes = activationReserveBytes
        self.postLoadMaximumKVBytes = postLoadMaximumKVBytes
    }

    public func cacheSnapshot() -> CacheSnapshot {
        CacheSnapshot(
            durableMode: bundle.bridge.ssdHybridCheckpointStore != nil ? "ssd_complete"
                : bundle.bridge.ssdPrefixCache != nil ? "ssd_attention" : nil,
            keyMode: bundle.bridge.ssdHybridCheckpointStore.map { $0.usesEphemeralKey ? "ephemeral" : "persistent" },
            status: bundle.bridge.prefixCacheModelStatus(),
            memoryEnabled: memoryEnabled,
            recurrentBankBudgetBytes: rawEngine.hybridPrefixCache?.config.maximumBytes ?? 0,
            engineKVCapacityBytes: rawEngine.capacity().kvBytesCapacity,
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
            activationReserveBytes: activationReserveBytes,
            postLoadMaximumKVBytes: postLoadMaximumKVBytes,
            checkpoints: bundle.bridge.ssdHybridCheckpointStore?.stats(),
            attention: bundle.bridge.ssdPrefixCache?.stats(),
            processMemory: memorySnapshot(), assistantIdentity: assistantIdentity,
            productionGrant: productionGrant, postBuildHeadroomBytes: postBuildHeadroomBytes)
    }

    /// Read the same coherent shared ledger used by this production slot.
    /// This benchmark-only capture never inspects mutable native pool state.
    public func memorySnapshot() -> ProcessMemoryTelemetry? {
        memorySampler.capture(budget.memoryHeadroomSnapshot())
    }

    /// Start the caller's TTFT clock BEFORE awaiting this method. It returns
    /// the engine's original stream after production SSD staging, without a
    /// relay task. Call complete(receiptID:) after fully draining that stream.
    public func submit(_ input: CBv2Request) async throws -> Submission {
        guard !closed else { throw Failure.closed }
        guard !active.values.contains(input.id) else { throw Failure.requestAlreadyActive }
        guard nextReceipt < UInt64.max else { throw Failure.receiptIDsExhausted }
        // Separate identity domain from deterministic sampling IDs. The maps
        // never treat a reused engine ID as ownership of an older submission.
        let receiptID = CBv2RequestID(nextReceipt)
        nextReceipt += 1
        active[receiptID] = input.id
        var request = input
        request.prefixCacheReceiptID = receiptID
        do {
            var stage: SSDPrefixCacheStageResult?
            if input.prefixCacheEnabled, input.multimodal == nil, input.positionState == nil {
                if let store = bundle.bridge.ssdHybridCheckpointStore {
                    let importRequest = request
                    stage = await store.stage(
                        requestID: receiptID, request: importRequest,
                        reserveReadScratch: { [rawEngine] in try rawEngine.reserveCompleteCheckpointReadScratch() }
                    ) { [rawEngine] in
                        try rawEngine.planCompleteCheckpointImport(manifest: $0, request: importRequest)
                    }
                } else if let store = bundle.bridge.ssdPrefixCache {
                    let resident = rawEngine.residentPrefixCandidate(for: request)
                    if resident == nil || store.estimatedPrefillTokensSaved(
                        promptTokens: input.promptTokens, cacheScope: input.cacheSalt ?? "")
                        > (resident?.prefillTokensSaved ?? 0) {
                        stage = await store.stage(
                            requestID: receiptID, promptTokens: input.promptTokens,
                            cacheScope: input.cacheSalt ?? "")
                    }
                }
            }
            try Task.checkCancellation()
            guard !closed else { throw Failure.closed }
            let events = try rawEngine.submit(request)
            return Submission(
                receiptID: receiptID, events: events,
                stageMilliseconds: stage?.stageMs ?? 0,
                stageDisposition: stage.map { Self.describe($0.disposition) } ?? "not_attempted")
        } catch {
            active.removeValue(forKey: receiptID)
            await retireStage(receiptID)
            throw error
        }
    }

    /// Caller drains the raw terminal first; this is the idempotent store
    /// backstop used by the production bridge's terminal pump as well.
    public func complete(receiptID: CBv2RequestID) async {
        guard active.removeValue(forKey: receiptID) != nil else { return }
        await retireStage(receiptID)
        // After a serial row, include the final actor-based refund in idle
        // metrics. An active concurrent row must not wait for another's stage.
        if active.isEmpty {
            await bundle.bridge.ssdHybridCheckpointStore?.activity.waitUntilDrained()
        }
    }

    private func retireStage(_ receiptID: CBv2RequestID) async {
        await bundle.bridge.ssdHybridCheckpointStore?.abandonStaging(requestID: receiptID)
        bundle.bridge.ssdHybridCheckpointStore?.discardReadyReceipt(requestID: receiptID)
        await bundle.bridge.ssdPrefixCache?.abandonStaging(requestID: receiptID)
        bundle.bridge.ssdPrefixCache?.discardReadyReceipt(requestID: receiptID)
    }

    public func shutdown() async {
        guard !closed else { return }
        closed = true
        await bundle.bridge.shutdown()
        active.removeAll()
        bundle.releaseAssistant()
    }

    private static func describe(_ disposition: SSDPrefixCacheStageDisposition) -> String {
        switch disposition {
        case .staged: "staged"
        case .missAbsent: "miss_absent"
        case .missCorrupt: "miss_corrupt"
        case .skippedCapacity: "skipped_capacity"
        case .skippedCost: "skipped_cost"
        case .skippedPolicy: "skipped_policy"
        }
    }
}
