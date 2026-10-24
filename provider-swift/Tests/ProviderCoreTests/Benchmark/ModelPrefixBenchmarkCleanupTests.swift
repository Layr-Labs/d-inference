import Foundation
import Testing

@_spi(Benchmarking) @testable import ProviderCore

@Suite("Native prefix benchmark cleanup")
struct ModelPrefixBenchmarkCleanupTests {
    @Test("unacknowledged native owners preserve their actual cache files")
    func nativeFailurePreservesOwnedRoot() throws {
        for failure in [EngineV2BenchmarkSession.Failure.nativeRetirementPending("pending"),
                        .nativeRetainedFault("failed native completion")] {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("prefix-cleanup-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let marker = root.appendingPathComponent("owned-cache-marker")
            try Data([1, 2, 3]).write(to: marker)
            ModelPrefixBenchmarkFixture.cleanupNativeRootAfterLoadFailure(root, error: failure)
            #expect(try Data(contentsOf: marker) == Data([1, 2, 3]))
        }
    }

    @Test("ordinary failed construction cleans its abandoned root")
    func ordinaryFailureRemovesRoot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("prefix-cleanup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        ModelPrefixBenchmarkFixture.cleanupNativeRootAfterLoadFailure(root,
            error: EngineV2BenchmarkSession.Failure.invalidVerifiedWeightHash)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }
}
