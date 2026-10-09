import Foundation
import Testing

struct ModelPrefixBenchmarkSpecification: Codable, Sendable {
    let modelID: String
    let openRouterID: String
    let directory: String
    let expectedWeightHash: String
    let modelType: String
    let outputPath: String
    let pairs: Int
    let outputTokens: Int
    var checkpointPartition: String? = nil
    var mtpEnabled: Bool? = nil
    var pairOffset: Int? = nil
    var soloPrefillStripeTokens: Int? = nil
    var captureTokenDiagnostics: Bool? = nil
    let cases: [Case]

    struct Case: Codable, Sendable {
        let name: String
        let donorTokens: Int
        let sharedTokens: Int
        let forkTokens: Int
        let demandedTokens: Int
        var adjacentFork: AdjacentFork? = nil
    }

    struct AdjacentFork: Codable, Sendable {
        let sharedTokens: Int
        let forkTokens: Int
        let expectedRestoredTokens: Int
    }

    static func load() throws -> Self {
        let path = try #require(ProcessInfo.processInfo.environment["DARKBLOOM_PREFIX_MODEL_SPEC"])
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        try value.validate()
        return value
    }

    enum ValidationFailure: Error {
        case invalidWorkloadBounds, invalidPairOffset, invalidPartition
        case invalidStripe, invalidCases, invalidTokenBounds, invalidAdjacentTokenBounds
    }

    func validate() throws {
        guard (1...5).contains(pairs), (32...512).contains(outputTokens)
        else { throw ValidationFailure.invalidWorkloadBounds }
        let offset = pairOffset ?? 0
        guard (0...4).contains(offset), offset + pairs <= 5
        else { throw ValidationFailure.invalidPairOffset }
        guard checkpointPartition == nil || checkpointPartition == "production"
            || checkpointPartition == "demanded_recurrent_qualification"
        else { throw ValidationFailure.invalidPartition }
        if let stripe = soloPrefillStripeTokens, !(32...8_192).contains(stripe) {
            throw ValidationFailure.invalidStripe
        }
        guard !cases.isEmpty, cases.count <= 4 else { throw ValidationFailure.invalidCases }
        for cell in cases {
            guard cell.donorTokens > cell.sharedTokens, cell.forkTokens > cell.sharedTokens,
                cell.sharedTokens >= cell.demandedTokens, cell.demandedTokens >= 1024,
                max(cell.donorTokens, cell.forkTokens) <= 20_000
            else { throw ValidationFailure.invalidTokenBounds }
            if let adjacent = cell.adjacentFork {
                guard adjacent.expectedRestoredTokens >= 1_024,
                    adjacent.expectedRestoredTokens.isMultiple(of: 256),
                    adjacent.expectedRestoredTokens > cell.demandedTokens,
                    adjacent.expectedRestoredTokens <= adjacent.sharedTokens,
                    adjacent.sharedTokens > cell.sharedTokens,
                    adjacent.sharedTokens < cell.donorTokens,
                    adjacent.forkTokens > adjacent.sharedTokens,
                    adjacent.forkTokens <= 20_000
                else { throw ValidationFailure.invalidAdjacentTokenBounds }
            }
        }
    }

}

struct ModelPrefixBenchmarkReport: Codable, Sendable {
    let modelID: String
    let openRouterID: String
    let weightHash: String
    let modelType: String
    let servingModelType: String
    let backend: String
    let backendFallback: String?
    let cacheMode: String?
    let keyMode: String?
    let mtpEnabled: Bool
    let checkpointPartition: String
    let strictFsync: Bool
    let productionKVGrantBytes: Int
    let physicalMemoryBytes: UInt64
    let activationReserveBytes: UInt64
    let outputTokens: Int
    let comparison: String
    var generationTPSDefinition: String? = ModelPrefixBenchmarkOutputTiming.definition
    var timingConvention: String? = "TTFT includes stage/submit through first nonempty raw output event; endToEndTPS uses the terminal event; receiptCompletionTPS uses return of session.complete after normal retirement and stage activity drain; quiescenceCompletionTPS additionally waits for engine idle and the owned checkpoint writer/activity drain; these are literal serialized-request rates, not saturation TPS or fsync durability claims"
    var schedulerConfiguration: ModelPrefixBenchmarkSchedulerConfiguration? = nil
    var tokenDiagnosticsEnabled: Bool? = nil
    var mtpRequested: Bool? = nil
    var mtpEffectiveActive: Bool? = nil
    var mtpQualified: Bool? = nil
    var assistantIdentity: [String: String]? = nil
    var rows: [ModelPrefixBenchmarkRow] = []
    var comparisons: [ModelPrefixBenchmarkComparison] = []
    var adjacentComparisons: [ModelPrefixBenchmarkAdjacentComparison]? = nil

    func save(to path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var saved = self
        saved.schedulerConfiguration = rows.first?.schedulerConfiguration
        saved.tokenDiagnosticsEnabled = rows.first.map { $0.tokenDiagnostics != nil }
        saved.mtpRequested = rows.first?.mtp.requested
        saved.mtpEffectiveActive = rows.first?.mtp.activeAfter
        saved.mtpQualified = rows.isEmpty ? nil : rows.allSatisfy { $0.mtp.qualified }
        try encoder.encode(saved).write(to: url, options: .atomic)
    }
}

struct ModelPrefixBenchmarkRow: Codable, Sendable {
    let cell: String
    let pair: Int
    let role: String
    let promptTokens: Int
    let completedOutputTokens: Int
    let firstOutputTokenCount: Int
    let outputEventCount: Int
    let targetTokens: Int?
    let firstOutputSeconds: Double
    let lastOutputSeconds: Double
    let terminalSeconds: Double
    let receiptCompletionSeconds: Double
    let quiescenceCompletionSeconds: Double
    let receiptToQuiescenceMilliseconds: Double
    let checkpointWritesDrained: Bool
    let generationTPS: Double?
    let endToEndTPS: Double
    let receiptCompletionTPS: Double
    let quiescenceCompletionTPS: Double
    let stageMilliseconds: Double
    let stageDisposition: String
    let restoredTokens: Int
    let matchedTokens: Int
    let replayTokens: Int
    let cacheTier: String?
    let outputSHA256: String
    let filesWrittenDelta: Int
    let bytesWrittenDelta: Int
    let filesReadDelta: Int
    let bytesReadDelta: Int
    let writeMillisecondsDelta: Double
    let packedPrefillChunks: UInt32
    let prefillChunks: UInt32
    let preemptions: UInt32
    let peakStagingBytes: Int
    let peakWriteHostBytes: Int
    let schedulerConfiguration: ModelPrefixBenchmarkSchedulerConfiguration
    let tokenDiagnostics: ModelPrefixBenchmarkTokenDiagnostics?
    let mtp: ModelPrefixBenchmarkMTPObservation
}

struct ModelPrefixBenchmarkComparison: Codable, Sendable {
    let cell: String
    let pair: Int
    let outputMatches: Bool
    let ttftReductionPercent: Double
    let totalLatencyReductionPercent: Double
    let endToEndTPSIncreasePercent: Double
    let donorOutputMatches: Bool
    let donorTTFTIncreasePercent: Double
    let checkpointBytesCreated: Int
    let warmRestoredTokens: Int
}
