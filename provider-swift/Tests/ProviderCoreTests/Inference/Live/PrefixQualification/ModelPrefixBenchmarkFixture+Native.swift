import Foundation
import MLXLMCommon
import ProviderCoreFoundation
import Testing

@_spi(Benchmarking) @testable import ProviderCore

extension ModelPrefixBenchmarkFixture {
    /// Full native artifacts still enter their ordinary owned load gate. This
    /// branch enables reproduction on a sufficiently provisioned machine; a
    /// small component fixture is never reported as full-model performance.
    static func prepareNative(_ specification: ModelPrefixBenchmarkSpecification,
                              directory: URL, verifiedHash: String, root: URL,
                              environment: [String: String]) async throws -> Owned {
        try #require(specification.checkpointPartition == nil
            || specification.checkpointPartition == "production")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let native: (container: ModelContainer, session: EngineV2BenchmarkSession)
        do {
            native = try await NativeHistoricalPrefixArchitecture.load(modelID: specification.modelID,
                directory: directory, verifiedWeightHash: verifiedHash, environment: environment,
                mtpEnabled: specification.mtpEnabled ?? false)
        } catch {
            Self.cleanupNativeRootAfterLoadFailure(root, error: error)
            throw error
        }
        do {
            let after = try #require(WeightHasher.computeHash(snapshotDir: directory, modelID: specification.modelID))
            try #require(after == verifiedHash, "native artifact bytes changed while loading")
            let tokenizer = await native.container.perform { TokenizerHandle($0.tokenizer) }
            let model = await native.container.perform { EngineV2ModelSnapshot(model: $0.model,
                eosTokenIds: $0.configuration.eosTokenIds, extraEOSTokens: $0.configuration.extraEOSTokens.sorted()) }
            let cache = await native.session.cacheSnapshot()
            try #require(cache.status.state == .ready && cache.durableMode == "ssd_complete")
            try #require(cache.keyMode == "ephemeral" && !cache.memoryEnabled)
            try #require(native.session.backendFallback == nil)
            return Owned(container: native.container, tokenizer: tokenizer, session: native.session,
                servingModelType: String(describing: type(of: model.model)), root: root)
        } catch {
            // A retained native fault must remain an explicit failure. Never
            // release external owners or remove their cache on a timeout.
            try await native.session.shutdownReportingCompletion()
            await EngineV2Factory.releaseBenchmarkContainer(native.container)
            SSDWholeRootMaintainer.shared.stopPeriodicMaintenance(root: root)
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    static func cleanupNativeRootAfterLoadFailure(_ root: URL, error: any Error) {
        if let failure = error as? EngineV2BenchmarkSession.Failure {
            switch failure {
            case .nativeRetirementPending, .nativeRetainedFault:
                // No acknowledged retirement: retained owners can still hold
                // their store. Preserve both its files and maintenance owner.
                return
            default: break
            }
        }
        SSDWholeRootMaintainer.shared.stopPeriodicMaintenance(root: root)
        try? FileManager.default.removeItem(at: root)
    }
}
