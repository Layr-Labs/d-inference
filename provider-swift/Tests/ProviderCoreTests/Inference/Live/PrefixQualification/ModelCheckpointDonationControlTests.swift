import CryptoKit
import Foundation
@testable import MLXLMCommon
import Testing

@_spi(Benchmarking) @testable import ProviderCore

@Suite("Matched-geometry checkpoint donation controls")
struct ModelCheckpointDonationControlTests {
    private var ranges: [ModelCheckpointPrefillRange] {
        [.init(lowerBound: 0, upperBound: 1_024, plannedCap: 2_048, packed: false),
         .init(lowerBound: 1_024, upperBound: 2_049, plannedCap: 2_048, packed: false)]
    }

    private var benchmark: ModelPrefixBenchmarkReport {
        var value = ModelPrefixBenchmarkReport(modelID: "fixture", openRouterID: "fixture/model",
            weightHash: "weights", modelType: "qwen3_5_moe", servingModelType: "Qwen35MoEModel",
            backend: "paged", backendFallback: nil, cacheMode: "ssd_complete", keyMode: "ephemeral",
            mtpEnabled: false, checkpointPartition: "demanded_recurrent_qualification", strictFsync: false,
            productionKVGrantBytes: 1 << 30, physicalMemoryBytes: 64 << 30, activationReserveBytes: 1 << 30,
            outputTokens: 64, comparison: "synthetic validation input, not model execution")
        value.schedulerConfiguration = .init(.init(maxConcurrentRequests: 1,
            maxBatchedTokensPerStep: 2_048, prefillChunkSize: 512, soloPrefillStripeTokens: 2_048,
            maxConcurrentPartialPrefills: 1, enablePrefixCache: true))
        value.liveKVQuantization = "native"
        value.checkpointQuantization = "balanced"
        value.checkpointBackendLayout = CBv2CompleteCheckpointManifest.nativeQuantizedPagedLayout
        value.runtimeIdentity = ["binary_sha256": "binary", "metallib_sha256": "metal"]
        return value
    }

    private func row(role: String, target: Int = 1_024, output: String = "full-64-token-digest") -> ModelPrefixBenchmarkRow {
        var value = ModelPrefixBenchmarkRow(cell: "long", pair: 0, role: role, promptTokens: 2_049,
            completedOutputTokens: 64, firstOutputTokenCount: 1, outputEventCount: 64, targetTokens: target,
            firstOutputSeconds: 1, lastOutputSeconds: 2, terminalSeconds: 2, receiptCompletionSeconds: 2,
            quiescenceCompletionSeconds: 2, receiptToQuiescenceMilliseconds: 0, checkpointWritesDrained: true,
            generationTPS: 63, endToEndTPS: 32, receiptCompletionTPS: 32, quiescenceCompletionTPS: 32,
            stageMilliseconds: 0, stageDisposition: "miss_absent", restoredTokens: 0, matchedTokens: 0,
            replayTokens: 0, cacheTier: nil, outputSHA256: output,
            filesWrittenDelta: role == "donor" ? 1 : 0, bytesWrittenDelta: role == "donor" ? 4_096 : 0,
            filesReadDelta: 0, bytesReadDelta: 0, writeMillisecondsDelta: 0,
            packedPrefillChunks: 0, prefillChunks: 2, preemptions: 0, peakStagingBytes: 0, peakWriteHostBytes: 0,
            schedulerConfiguration: benchmark.schedulerConfiguration!, tokenDiagnostics: nil,
            mtp: .init(requested: false, before: nil, after: nil))
        value.stageConsumptionsDelta = 0
        value.stagedBytesAfterRetirement = 0
        value.writeHostBytesAfterRetirement = 0
        value.promptSHA256 = "donor-prompt"
        value.prefixCacheEnabled = true
        value.samplingRequestID = 11
        value.samplingTemperature = 0
        value.stopTokenCount = 0
        value.cacheScopeSHA256 = "scope"
        value.prefillRanges = ranges
        return value
    }

    private func control(_ row: ModelPrefixBenchmarkRow? = nil) -> ModelCheckpointDonationControl {
        .init(cell: "long", pair: 0, controlRow: row ?? self.row(role: "donation_control"), benchmark: benchmark,
            cacheWitness: .init(state: "ready", durableMode: "ssd_complete", memoryEnabled: false,
                maxStageBytes: 1 << 20, manifestAllowanceBytes: 1 << 20, checkpointFiles: 0), warmupIterations: 1)
    }

    @Test("both requests retain the same positive demand and raw fixed-output sampling")
    func matchedRequest() {
        let tokens = Array(repeating: 37, count: 8_205)
        let request = ModelPrefixBenchmarkFixture.benchmarkRequest(tokens: tokens, scope: "control-scope",
            target: 7_168, cacheEnabled: true, outputTokens: 64)
        #expect(request.prefixCacheEnabled && request.prefixCheckpointTargetTokens == 7_168)
        #expect(request.promptTokens == tokens && request.cacheSalt == "control-scope")
        #expect(request.id.raw == 11 && request.sampling.temperature == 0 && request.maxTokens == 64)
        #expect(request.stopTokens.isEmpty && request.stopStrings.isEmpty)
    }

    @Test("a real one-MiB store refuses positive capture while a normal store accepts it")
    func realCaptureAdmission() throws {
        let root = try SSDTestDirectory.parent().appendingPathComponent("donation-control-\(UUID().uuidString)")
        let modelRoot = root.appendingPathComponent("0123456789ab")
        try SSDBlockStore.prepareModelRoot(dedicatedRoot: root, modelRoot: modelRoot)
        defer { try? FileManager.default.removeItem(at: root) }
        let identity = CBv2CompleteCheckpointIdentity(modelAggregateHash: "weights", promptContractID: "prompt",
            buildID: "build", numericsFingerprint: "numerics")
        func makeStore(cap: Int) -> SSDHybridCheckpointStore {
            SSDHybridCheckpointStore(config: .init(modelId: "fixture", identity: identity,
                root: modelRoot, dedicatedRoot: root, epochStore: nil, maxReadBytes: cap,
                maxStageMillis: 1_000, minEffectiveTokens: 1_024, ttlSeconds: 1_800,
                strictFsync: false, nowSeconds: { 0 }, diskBudgetBytes: { 1 << 30 }, maintainWholeRoot: {}),
                kekKey: SymmetricKey(size: .bits256), kvBudget: nil, maxWriteBytesPerDay: 1 << 30)
        }
        let limited = makeStore(cap: ModelCheckpointDonationControl.maximumStageBytes)
        let normal = makeStore(cap: 16 << 20)
        defer { limited.close(); normal.close() }
        #expect(CBv2CompleteCheckpointManifest.maximumEncodedBytes == 1 << 20)
        #expect(!limited.isClosed && limited.config.maxReadBytes == 1 << 20)
        for bytes in [1, 1 << 20, Int.max] {
            #expect(!limited.acceptsCheckpoint(position: 1_024, packedBytes: bytes))
        }
        #expect(normal.acceptsCheckpoint(position: 1_024, packedBytes: 1))
        #expect(limited.stats().filesWritten == 0 && limited.stats().filesRead == 0)
        #expect(try ModelCheckpointStorageArtifact.checkpointFiles(in: root).isEmpty)
    }

    @Test("executed traces must cover the exact prompt without gaps, overlap or overruns")
    func invalidTraces() throws {
        try ModelCheckpointPrefillRange.validate(ranges, promptTokens: 2_049,
            prefillChunks: 2, packedPrefillChunks: 0, preemptions: 0)
        let invalid: [[ModelCheckpointPrefillRange]] = [
            [],
            [.init(lowerBound: -1, upperBound: 1_024, plannedCap: 2_048, packed: false), ranges[1]],
            [ranges[0], .init(lowerBound: 1_025, upperBound: 2_049, plannedCap: 2_048, packed: false)],
            [ranges[0], .init(lowerBound: 1_023, upperBound: 2_049, plannedCap: 2_048, packed: false)],
            [ranges[0], .init(lowerBound: 1_024, upperBound: 2_050, plannedCap: 2_048, packed: false)],
            [ranges[0], .init(lowerBound: 1_024, upperBound: 2_048, plannedCap: 2_048, packed: false)],
            [.init(lowerBound: 0, upperBound: 1_024, plannedCap: 512, packed: false), ranges[1]],
            [.init(lowerBound: 0, upperBound: 1_024, plannedCap: 2_048, packed: true), ranges[1]]
        ]
        for trace in invalid {
            #expect(throws: (any Error).self) {
                try ModelCheckpointPrefillRange.validate(trace, promptTokens: 2_049,
                    prefillChunks: 2, packedPrefillChunks: 0, preemptions: 0)
            }
        }
        let invalidCounters: [(UInt32, UInt32, UInt32)] = [(3, 0, 0), (2, 1, 0), (2, 0, 1)]
        for (chunks, packed, preemptions) in invalidCounters {
            #expect(throws: (any Error).self) {
                try ModelCheckpointPrefillRange.validate(ranges, promptTokens: 2_049,
                    prefillChunks: chunks, packedPrefillChunks: packed, preemptions: preemptions)
            }
        }
    }

    @Test("equal counts or equal outputs cannot excuse unequal partitions")
    func unequalPartitions() throws {
        let baseline = control()
        var donor = row(role: "donor")
        try baseline.validate(donor: donor, actual: benchmark)
        donor.prefillRanges = [
            .init(lowerBound: 0, upperBound: 512, plannedCap: 2_048, packed: false),
            .init(lowerBound: 512, upperBound: 2_049, plannedCap: 2_048, packed: false)]
        #expect(throws: ModelCheckpointDonationControl.Failure.geometryMismatch) {
            try baseline.validate(donor: donor, actual: benchmark)
        }
    }

    @Test("novel or disabled requests cannot serve as the export control")
    func invalidRequestControls() {
        let donor = row(role: "donor")
        #expect(throws: ModelCheckpointDonationControl.Failure.requestMismatch) {
            try control(row(role: "donation_control", target: 0)).validate(donor: donor, actual: benchmark)
        }
        var disabled = row(role: "donation_control")
        disabled.prefixCacheEnabled = false
        #expect(throws: ModelCheckpointDonationControl.Failure.requestMismatch) {
            try control(disabled).validate(donor: donor, actual: benchmark)
        }
        var stopped = row(role: "donation_control")
        stopped.stopTokenCount = 1
        #expect(throws: ModelCheckpointDonationControl.Failure.requestMismatch) {
            try control(stopped).validate(donor: donor, actual: benchmark)
        }
    }

    @Test("full fixed-budget output digest equality remains mandatory")
    func fullOutputEquality() {
        #expect(throws: ModelCheckpointDonationControl.Failure.outputMismatch) {
            try control().validate(donor: row(role: "donor", output: "different-after-EOS"), actual: benchmark)
        }
    }

    @Test("current reports cannot decode archived unversioned control evidence")
    func explicitReportVersion() throws {
        let report = ModelCheckpointStorageReport(runID: UUID(), phase: .benchmark, processID: 1,
            startedAt: Date(), checkpointRoot: nil, keyNamespaceID: nil, keyAccessGroup: nil,
            artifactDirectory: "/tmp/model", workload: "fixture", warmupIterations: 1, benchmark: benchmark)
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        #expect(object["donationControlVersion"] as? Int == 1)
        object.removeValue(forKey: "donationControlVersion")
        let archived = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(ModelCheckpointStorageReport.self, from: archived) }
    }
}
