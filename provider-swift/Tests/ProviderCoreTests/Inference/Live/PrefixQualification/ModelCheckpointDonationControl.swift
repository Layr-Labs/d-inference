import Foundation
@testable import MLXLMCommon
import Testing

@_spi(Benchmarking) @testable import ProviderCore

struct ModelCheckpointDonationControl: Codable, Sendable {
    static let maximumStageBytes = 1 << 20

    struct CacheWitness: Codable, Sendable {
        let state: String
        let durableMode: String?
        let memoryEnabled: Bool
        let maxStageBytes: Int
        let manifestAllowanceBytes: Int
        let checkpointFiles: Int
    }

    enum Failure: Error, Equatable {
        case observerAlreadyInstalled, invalidCache, requestMismatch, geometryMismatch, modelMismatch
        case unexpectedIO, incompleteRequest, outputMismatch
    }

    let cell: String
    let pair: Int
    let controlRow: ModelPrefixBenchmarkRow
    let benchmark: ModelPrefixBenchmarkReport
    let cacheWitness: CacheWitness
    let warmupIterations: Int

    static func cacheWitness(_ fixture: ModelPrefixBenchmarkFixture) async throws -> CacheWitness {
        let snapshot = await fixture.session.cacheSnapshot()
        let store = try #require(fixture.session.rawEngine.completePrefixCache as? SSDHybridCheckpointStore,
            "the control requires the real complete checkpoint store")
        guard snapshot.status.state == .ready, snapshot.durableMode == "ssd_complete",
            !snapshot.memoryEnabled, !store.isClosed,
            store.config.maxReadBytes == maximumStageBytes,
            CBv2CompleteCheckpointManifest.maximumEncodedBytes == maximumStageBytes,
            !store.acceptsCheckpoint(position: store.config.minEffectiveTokens, packedBytes: 1)
        else { throw Failure.invalidCache }
        let count = try ModelCheckpointStorageArtifact.checkpointFiles(in: fixture.root).count
        guard count == 0 else { throw Failure.unexpectedIO }
        return CacheWitness(state: "ready", durableMode: snapshot.durableMode,
            memoryEnabled: snapshot.memoryEnabled, maxStageBytes: store.config.maxReadBytes,
            manifestAllowanceBytes: CBv2CompleteCheckpointManifest.maximumEncodedBytes, checkpointFiles: count)
    }

    func validate(donor: ModelPrefixBenchmarkRow, actual: ModelPrefixBenchmarkReport) throws {
        let control = controlRow
        guard cacheWitness.state == "ready", cacheWitness.durableMode == "ssd_complete",
            !cacheWitness.memoryEnabled, cacheWitness.maxStageBytes == Self.maximumStageBytes,
            cacheWitness.manifestAllowanceBytes == Self.maximumStageBytes, cacheWitness.checkpointFiles == 0
        else { throw Failure.invalidCache }
        guard cell == donor.cell, pair == donor.pair, control.cell == cell, control.pair == pair,
            control.role == "donation_control", donor.role == "donor",
            let target = control.targetTokens, target > 0, target == donor.targetTokens,
            control.promptTokens == donor.promptTokens, control.promptSHA256 != nil,
            control.promptSHA256 == donor.promptSHA256,
            control.prefixCacheEnabled == true, donor.prefixCacheEnabled == true,
            control.samplingRequestID == 11, donor.samplingRequestID == control.samplingRequestID,
            control.samplingTemperature == 0, donor.samplingTemperature == control.samplingTemperature,
            control.stopTokenCount == 0, donor.stopTokenCount == control.stopTokenCount,
            control.cacheScopeSHA256 != nil, control.cacheScopeSHA256 == donor.cacheScopeSHA256,
            control.schedulerConfiguration == donor.schedulerConfiguration,
            control.schedulerConfiguration == actual.schedulerConfiguration
        else { throw Failure.requestMismatch }
        guard benchmark.modelID == actual.modelID, benchmark.openRouterID == actual.openRouterID,
            benchmark.weightHash == actual.weightHash, benchmark.modelType == actual.modelType,
            benchmark.servingModelType == actual.servingModelType,
            benchmark.backend == actual.backend, benchmark.backendFallback == nil, actual.backendFallback == nil,
            benchmark.cacheMode == actual.cacheMode, benchmark.keyMode == actual.keyMode,
            benchmark.mtpEnabled == actual.mtpEnabled, benchmark.assistantIdentity == actual.assistantIdentity,
            benchmark.checkpointPartition == actual.checkpointPartition,
            benchmark.strictFsync == actual.strictFsync,
            benchmark.productionKVGrantBytes == actual.productionKVGrantBytes,
            benchmark.physicalMemoryBytes == actual.physicalMemoryBytes,
            benchmark.activationReserveBytes == actual.activationReserveBytes,
            benchmark.outputTokens == actual.outputTokens,
            benchmark.schedulerConfiguration == actual.schedulerConfiguration,
            benchmark.runtimeIdentity == actual.runtimeIdentity,
            benchmark.liveKVQuantization == actual.liveKVQuantization,
            benchmark.checkpointQuantization == actual.checkpointQuantization,
            benchmark.checkpointBackendLayout == actual.checkpointBackendLayout,
            benchmark.executionStorage == actual.executionStorage
        else { throw Failure.modelMismatch }
        for row in [control, donor] {
            guard row.completedOutputTokens == actual.outputTokens, row.checkpointWritesDrained,
                row.stagedBytesAfterRetirement == 0, row.writeHostBytesAfterRetirement == 0, row.mtp.qualified
            else { throw Failure.incompleteRequest }
            guard row.filesReadDelta == 0, row.bytesReadDelta == 0,
                row.restoredTokens == 0, row.matchedTokens == 0, row.replayTokens == 0,
                row.stageConsumptionsDelta == 0
            else { throw Failure.unexpectedIO }
            guard let ranges = row.prefillRanges else { throw ModelCheckpointPrefillRange.Failure.missingRanges }
            try ModelCheckpointPrefillRange.validate(ranges, promptTokens: row.promptTokens,
                prefillChunks: row.prefillChunks, packedPrefillChunks: row.packedPrefillChunks,
                preemptions: row.preemptions)
        }
        guard control.filesWrittenDelta == 0, control.bytesWrittenDelta == 0,
            donor.filesWrittenDelta > 0, donor.bytesWrittenDelta > 0 else { throw Failure.unexpectedIO }
        guard control.prefillRanges == donor.prefillRanges else { throw Failure.geometryMismatch }
        guard control.outputSHA256 == donor.outputSHA256 else { throw Failure.outputMismatch }
    }
}
