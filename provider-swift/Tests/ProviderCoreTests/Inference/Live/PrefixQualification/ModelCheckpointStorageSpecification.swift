import Foundation
import Testing

@_spi(Benchmarking) @testable import ProviderCore

struct ModelCheckpointStorageSpecification: Codable, Sendable {
    enum Phase: String, Codable, Sendable { case benchmark, donate, restore, refuse }

    let benchmark: ModelPrefixBenchmarkSpecification
    let runID: UUID
    let phase: Phase
    var checkpointRoot: String? = nil
    var keyNamespaceID: UUID? = nil
    var keyAccessGroup: String? = nil
    var producerReportPath: String? = nil

    enum Failure: Error {
        case invalidPhaseConfiguration, diagnosticsInPerformanceRun, unsupportedNativeRestart
        case ambiguousCaseNames
    }

    var namespace: SSDPersistentTestKeyNamespace? {
        get throws {
            guard let keyNamespaceID, let keyAccessGroup else { return nil }
            return try SSDPersistentTestKeyNamespace(identifier: keyNamespaceID, accessGroup: keyAccessGroup)
        }
    }

    func validate() throws {
        try benchmark.validate()
        guard Set(benchmark.cases.map(\.name)).count == benchmark.cases.count,
            benchmark.cases.allSatisfy({ !$0.name.isEmpty && $0.name.utf8.count <= 128 })
        else { throw Failure.ambiguousCaseNames }
        guard benchmark.captureTokenDiagnostics != true else { throw Failure.diagnosticsInPerformanceRun }
        if phase == .benchmark {
            guard checkpointRoot == nil, keyNamespaceID == nil, keyAccessGroup == nil,
                producerReportPath == nil else { throw Failure.invalidPhaseConfiguration }
            return
        }
        guard benchmark.modelType != "mimo_v2" else { throw Failure.unsupportedNativeRestart }
        guard let checkpointRoot, let namespace = try namespace,
            (phase == .donate) == (producerReportPath == nil),
            producerReportPath != benchmark.outputPath
        else { throw Failure.invalidPhaseConfiguration }
        var environment = ModelPrefixBenchmarkFixture.checkpointEnvironment(
            root: URL(fileURLWithPath: checkpointRoot), soloPrefillStripeTokens: nil)
        environment["DARKBLOOM_PREFIX_CACHE_TEST_PERSISTENT_KEY"] = "1"
        try namespace.validate(environment: environment)
    }

    static func load() throws -> Self {
        let path = try #require(ProcessInfo.processInfo.environment["DARKBLOOM_CHECKPOINT_STORAGE_SPEC"])
        let spec = try JSONDecoder().decode(Self.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        try spec.validate()
        return spec
    }
}

struct ModelCheckpointStorageComparison: Codable, Sendable {
    let cell: String
    let pair: Int
    let coldMatchesRestored: Bool
    let repeatedRestoreMatches: Bool
    let ttftReductionPercent: Double
    let generationTPSChangePercent: Double?
    let checkpointFileBytesWritten: Int
    let restoredTokens: Int
    let actualSharedTokens: Int
}

struct ModelCheckpointStorageReport: Codable, Sendable {
    static let currentDonationControlVersion = 1

    var donationControlVersion = currentDonationControlVersion
    let runID: UUID
    let phase: ModelCheckpointStorageSpecification.Phase
    let processID: Int32
    let startedAt: Date
    let checkpointRoot: String?
    let keyNamespaceID: UUID?
    let keyAccessGroup: String?
    let artifactDirectory: String
    let workload: String
    var warmupIterations: Int
    var completedIterations = 0
    var complete = false
    var failure: String? = nil
    var producerProcessID: Int32? = nil
    var benchmark: ModelPrefixBenchmarkReport
    var comparisons: [ModelCheckpointStorageComparison] = []
    var cancellations: [ModelCheckpointStorageCancellation] = []
    var authenticatedArtifacts: [ModelCheckpointStorageArtifact]? = nil
    var donationControls: [ModelCheckpointDonationControl] = []

    func save(to path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    static func load(from path: String) throws -> Self {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Self.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }

    func validateProducer(_ producer: Self) throws {
        try #require(producer.donationControlVersion == Self.currentDonationControlVersion
            && !producer.donationControls.isEmpty,
            "restart requires the current matched-geometry donor control, not archived novel-demand evidence")
        try #require(producer.complete && producer.failure == nil && producer.phase == .donate,
            "restart requires a completed donor report, not an attempted or fabricated cache hit")
        try #require(producer.runID == runID && producer.processID != processID
            && producer.startedAt <= startedAt, "restart must use a distinct subsequent process")
        try #require(producer.checkpointRoot == checkpointRoot && producer.keyNamespaceID == keyNamespaceID
            && producer.keyAccessGroup == keyAccessGroup && producer.artifactDirectory == artifactDirectory)
        try #require(producer.benchmark.modelID == benchmark.modelID
            && producer.benchmark.weightHash == benchmark.weightHash
            && producer.benchmark.servingModelType == benchmark.servingModelType
            && producer.benchmark.backend == benchmark.backend
            && producer.benchmark.mtpEnabled == benchmark.mtpEnabled
            && producer.benchmark.checkpointPartition == benchmark.checkpointPartition
            && producer.benchmark.schedulerConfiguration == benchmark.schedulerConfiguration
            && producer.benchmark.runtimeIdentity == benchmark.runtimeIdentity
            && producer.benchmark.liveKVQuantization == benchmark.liveKVQuantization
            && producer.benchmark.checkpointQuantization == benchmark.checkpointQuantization
            && producer.benchmark.checkpointBackendLayout == benchmark.checkpointBackendLayout,
            "restart must retain the actual model, binary, metallib, precision and layout identity")
    }
}
