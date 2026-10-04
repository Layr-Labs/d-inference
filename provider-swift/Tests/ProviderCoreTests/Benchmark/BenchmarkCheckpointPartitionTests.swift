import MLXLMCommon
import Testing

@_spi(Benchmarking) @testable import ProviderCore

@Suite("Benchmark checkpoint partition policy")
struct BenchmarkCheckpointPartitionTests {
    @Test("candidate policy requires every existing recurrent paged store gate")
    func candidateGate() {
        func minimum(
            purpose: EngineV2Factory.ConstructionPurpose = .benchmark,
            partition: EngineV2BenchmarkCheckpointPartition = .demandedRecurrentQualification,
            backend: EngineV2KVBackendKind = .paged,
            layout: String = CBv2CompleteCheckpointManifest.pagedLayout,
            floor: Int = 1_024, recurrent: Bool = true
        ) -> Int? {
            EngineV2Factory.benchmarkRecurrentShortCheckpointMinimumTokens(
                constructionPurpose: purpose, checkpointPartition: partition,
                backend: backend, backendLayout: layout,
                minimumTokens: floor, hasRecurrentState: recurrent)
        }
        #expect(minimum() == 1_024)
        #expect(minimum(floor: 2_048) == 2_048, "an existing higher floor stays higher")
        #expect(minimum(purpose: .serving) == nil, "qualification never activates serving")
        #expect(minimum(partition: .production) == nil)
        #expect(minimum(backend: .contiguous) == nil)
        #expect(minimum(layout: CBv2CompleteCheckpointManifest.historicalAttentionLayout) == nil)
        #expect(minimum(layout: CBv2CompleteCheckpointManifest.pagedAsymmetricMTPLayout) == nil)
        #expect(minimum(floor: 1_023) == nil)
        #expect(minimum(recurrent: false) == nil)
    }
}
