import Foundation
@testable import MLXLMCommon

@_spi(Benchmarking) @testable import ProviderCore

/// Read immutable geometry on the engine queue, not from requested flags.
struct ModelPrefixBenchmarkExecutionStorage: Codable, Sendable, Equatable {
    let paged: Bool
    let quantizedGroupCount: Int?
    let layerDTypes: [String]?
    let supportsOrdinaryDecodeChaining: Bool?

    init(session: EngineV2BenchmarkSession) {
        let loop = session.rawEngine.loopForTesting
        self = loop.onEngineQueueSync {
            let backend = loop.backend as? PagedKVBackend
            return Self(paged: backend != nil,
                quantizedGroupCount: backend.map { $0.pool.groupKeys.filter { $0.quantization != nil }.count },
                layerDTypes: backend.map { $0.pool.layerDTypes.map { String(describing: $0) } },
                supportsOrdinaryDecodeChaining: backend?.supportsOrdinaryDecodeChaining)
        }
    }

    private init(paged: Bool, quantizedGroupCount: Int?, layerDTypes: [String]?,
                 supportsOrdinaryDecodeChaining: Bool?) {
        self.paged = paged
        self.quantizedGroupCount = quantizedGroupCount
        self.layerDTypes = layerDTypes
        self.supportsOrdinaryDecodeChaining = supportsOrdinaryDecodeChaining
    }
}

/// Published capacity plus direct backend scalars at the post-retirement barrier.
struct ModelPrefixBenchmarkMemoryObservation: Codable, Sendable {
    let kvBytesInUse: Int
    let kvBytesReserved: Int
    let kvBytesCapacity: Int
    let pagedGeneration: UUID?
    let pagedCommittedBytes: Int?
    let pagedLiveBytes: Int?
    let pagedReservedBytes: Int?
    var backendBytesInUse: Int? = nil
    var backendBytesReserved: Int? = nil

    init(_ capacity: CBv2CapacitySnapshot) {
        kvBytesInUse = capacity.kvBytesInUse
        kvBytesReserved = capacity.kvBytesReserved
        kvBytesCapacity = capacity.kvBytesCapacity
        pagedGeneration = capacity.pagedStorage?.generation
        pagedCommittedBytes = capacity.pagedStorage?.committedBytes
        pagedLiveBytes = capacity.pagedStorage?.livePageBytes
        pagedReservedBytes = capacity.pagedStorage?.reservedPageBytes
    }
}

/// A public-fixture marker observation, not a general model-quality score.
struct ModelPrefixBenchmarkPublicOutput: Codable, Sendable {
    let expectedMarker: String
    let containsExpectedMarker: Bool
    let decodedText: String
    let tokenIDs: [Int]
}

extension ModelPrefixBenchmarkFixture {
    func memoryObservation() -> ModelPrefixBenchmarkMemoryObservation {
        let loop = session.rawEngine.loopForTesting
        return loop.onEngineQueueSync {
            var observation = ModelPrefixBenchmarkMemoryObservation(session.rawEngine.capacity())
            // A delta can reach its consumer before the next gauge publication.
            // Sample the actual live backend only while owning its engine queue.
            observation.backendBytesInUse = loop.backend.bytesInUse
            observation.backendBytesReserved = loop.backend.bytesReserved
            return observation
        }
    }

    func makeReport(comparison: String) async -> ModelPrefixBenchmarkReport {
        let cache = await session.cacheSnapshot()
        var report = ModelPrefixBenchmarkReport(modelID: specification.modelID,
            openRouterID: specification.openRouterID, weightHash: specification.expectedWeightHash,
            modelType: specification.modelType, servingModelType: servingModelType,
            backend: session.backend, backendFallback: session.backendFallback,
            cacheMode: cache.durableMode, keyMode: cache.keyMode,
            mtpEnabled: specification.mtpEnabled ?? false,
            checkpointPartition: specification.checkpointPartition ?? "production", strictFsync: false,
            productionKVGrantBytes: cache.engineKVCapacityBytes, physicalMemoryBytes: cache.physicalMemoryBytes,
            activationReserveBytes: cache.activationReserveBytes, outputTokens: specification.outputTokens,
            comparison: comparison)
        report.assistantIdentity = cache.assistantIdentity
        report.requestedLiveKVQuantization = specification.resolvedLiveKVQuantization
        report.requestedCheckpointQuantization = specification.resolvedCheckpointQuantization
        report.liveKVQuantization = session.kvQuantization.rawValue
        report.checkpointQuantization = session.kvCheckpointQuantization.rawValue
        report.checkpointBackendLayout = session.checkpointBackendLayout
        report.runtimeIdentity = EngineV2Factory.benchmarkRuntimeIdentity()
        report.executionStorage = ModelPrefixBenchmarkExecutionStorage(session: session)
        report.schedulerConfiguration = schedulerConfiguration
        report.tokenDiagnosticsEnabled = specification.captureTokenDiagnostics == true
        return report
    }
}
