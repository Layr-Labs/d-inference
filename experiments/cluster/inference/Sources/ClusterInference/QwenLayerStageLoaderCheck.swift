import Foundation
import MLX
import MLXNN

struct QwenLayerStageLoaderCheckResult: Encodable {
    let kind = "qwen_layer_stage_loader_check"
    let syntheticDType: String
    let wrapped: Bool
    let fp16LayerMetadata: Bool
    let fp16MetadataTensorCount: Int
    let tensorChecks: Int
    let tensorChecksAfterSourceDeletion: Int
    let sourceTensorBytes: Int
    let activeTensorBytes: [Int]
    let inertTensorBytes: [Int]
    let receipts: [QwenLayerStageLoadReceipt]
    let badAggregateRejectedStages: [Int]
    let corruptedSourceRejectedStages: [Int]
    let allActiveShapesDTypesAndBytesMatchOrdinary = true
    let activeNamesAndBytesConserveCanonicalSource = true
    let independentCompactZeroOffsetActiveBuffersBeforeForward = true
    let previouslyLoadedParameterHandlesUnchangedOnRejection = true
    let inactiveParametersCheckedSeparately = true
    let sourceFilesCorruptedAndDeleted = true
    let loaderProofPrecedesAnyTransformerForward = true
    let modelForwardCompared = false
}

/// Root calls completeLoaderProof() BEFORE constructing/running sessions.
/// Native GDN fusion may legitimately replace named parameter arrays with views
/// during a later forward, so this check must not promise per-parameter unique
/// allocations after session execution. Resident stages/baseline survive the
/// owned fixture's corruption/deletion and can then exercise model parity.
final class QwenLayerStageLoaderCheck {
    private typealias Oracle = QwenLayerStageLoaderOracle
    let stages: [LoadedQwenLayerStage]
    private(set) var loaderProofCompleted = false
    private let fixture: QwenLayerStageFixture
    private let expected: [[String: MLXArray]]
    private let expectedRecords: [[QwenStageActiveTensor]]
    private let activeBytes: [Int]
    private let inertBytes: [Int]
    private let sourceBytes: Int
    private let badAggregateRejectedStages: [Int]

    init(fixture: QwenLayerStageFixture, check: () throws -> Void = {}) throws {
        let baseline = Dictionary(uniqueKeysWithValues: fixture.baseline.model.parameters().flattened())
        guard baseline.count == 237, Set(baseline.keys) == Set(fixture.fixture.parameters.keys),
              fixture.baseline.layerCount == 8, fixture.plan.layers == 8, fixture.plan.interval == 4 else {
            throw ProbeError("Stage-loader check requires the full ordinary tiny8 baseline")
        }
        let records = try Oracle.expectedMappings(fixture: fixture, baseline: baseline)
        let expected = records.map { entries in
            Dictionary(uniqueKeysWithValues: entries.map { ($0.localName, baseline[$0.sourceName]!) })
        }
        let sourceBytes = fixture.fixture.parameters.values.reduce(0) { $0 + $1.nbytes }
        let activeBytes = records.map { $0.reduce(0) { $0 + $1.byteCount } }
        guard records.map(\.count) == [118, 119], activeBytes.reduce(0, +) == sourceBytes,
              Set(records[0].map(\.sourceName)).isDisjoint(with: Set(records[1].map(\.sourceName))),
              Set(records.flatMap { $0.map(\.sourceName) }) == Set(baseline.keys),
              baseline.values.reduce(0, { $0 + $1.nbytes }) == sourceBytes else {
            throw ProbeError("Independent stage ownership does not conserve ordinary canonical parameters")
        }
        var stages: [LoadedQwenLayerStage] = []
        var inertBytes: [Int] = []
        for index in 0..<2 {
            let stage = try loadVerifiedQwenLayerStage(directory: fixture.directory,
                originalConfiguration: fixture.baseline.configurationData, plan: fixture.plan,
                stageIndex: index, expectedAggregateSHA256: fixture.fixture.aggregateSHA256)
            try check()
            let checked = try Oracle.checkStorage(stage, expected: expected[index], phase: "after verified load")
            let inert = try Oracle.checkInert(stage, fixture: fixture)
            guard checked.checks == records[index].count, checked.bytes == activeBytes[index],
                  stage.stageIndex == index, stage.layerCount == 4, stage.vocabularySize == 512,
                  String(describing: stage.activationDType) == fixture.baseline.embeddingActivationDType else {
                throw ProbeError("Compact stage runtime metadata or active storage differs")
            }
            try Oracle.checkReceipt(stage, fixture: fixture, records: records[index],
                sourceBytes: sourceBytes, activeBytes: activeBytes[index], inertBytes: inert)
            stages.append(stage)
            inertBytes.append(inert)
        }
        guard try canonicalJSONData(stages[0].receipt.storageCommitment)
            == canonicalJSONData(stages[1].receipt.storageCommitment) else {
            throw ProbeError("Independent stage loads disagree on common storage commitment")
        }
        let wrongAggregate = (fixture.fixture.aggregateSHA256.first == "0" ? "1" : "0")
            + String(fixture.fixture.aggregateSHA256.dropFirst())
        let before = stages.map { Dictionary(uniqueKeysWithValues: $0.model.parameters().flattened()) }
        var rejected: [Int] = []
        for index in 0..<2 {
            do {
                _ = try loadVerifiedQwenLayerStage(directory: fixture.directory,
                    originalConfiguration: fixture.baseline.configurationData, plan: fixture.plan,
                    stageIndex: index, expectedAggregateSHA256: wrongAggregate)
            } catch {
                guard String(describing: error).contains("Checkpoint manifest differs from expected aggregate") else {
                    throw ProbeError("Bad stage aggregate failed for an unexpected reason: \(error)")
                }
                rejected.append(index)
            }
        }
        guard rejected == [0, 1] else { throw ProbeError("A bad aggregate returned a loaded stage") }
        try Oracle.checkUnchangedHandles(stages, before: before)
        try check()
        self.fixture = fixture
        self.stages = stages
        self.expected = expected
        self.expectedRecords = records
        self.sourceBytes = sourceBytes
        self.activeBytes = activeBytes
        self.inertBytes = inertBytes
        self.badAggregateRejectedStages = rejected
    }

    /// Corrupt/delete only this new temporary fixture. The ordinary baseline and
    /// both verified stages were already loaded and remain available to root.
    func completeLoaderProof(check: () throws -> Void = {}) throws -> QwenLayerStageLoaderCheckResult {
        guard !loaderProofCompleted, FileManager.default.fileExists(atPath: fixture.directory.path) else {
            throw ProbeError("Loader proof already completed or source disappeared prematurely")
        }
        let before = stages.map { Dictionary(uniqueKeysWithValues: $0.model.parameters().flattened()) }
        let checkpoint = fixture.directory.appendingPathComponent("weights-0.safetensors")
        var corrupted = try Data(contentsOf: checkpoint)
        guard !corrupted.isEmpty else { throw ProbeError("Empty owned checkpoint corruption fixture") }
        corrupted[corrupted.count - 1] ^= 1
        try corrupted.write(to: checkpoint)
        var rejected: [Int] = []
        for index in 0..<2 {
            do {
                _ = try loadVerifiedQwenLayerStage(directory: fixture.directory,
                    originalConfiguration: fixture.baseline.configurationData, plan: fixture.plan,
                    stageIndex: index, expectedAggregateSHA256: fixture.fixture.aggregateSHA256)
            } catch {
                guard String(describing: error).contains("SHA256 mismatch") else {
                    throw ProbeError("Corrupted stage source failed for an unexpected reason: \(error)")
                }
                rejected.append(index)
            }
        }
        guard rejected == [0, 1] else { throw ProbeError("A corrupted source returned a loaded stage") }
        try Oracle.checkUnchangedHandles(stages, before: before)
        try FileManager.default.removeItem(at: fixture.directory)
        guard !FileManager.default.fileExists(atPath: fixture.directory.path) else {
            throw ProbeError("Owned fixture source files remain after deletion")
        }
        var count = 0
        for index in 0..<2 {
            let checked = try Oracle.checkStorage(stages[index], expected: expected[index],
                phase: "after source corruption/deletion, before transformer forward")
            guard checked.checks == expectedRecords[index].count, checked.bytes == activeBytes[index],
                  try Oracle.checkInert(stages[index], fixture: fixture) == inertBytes[index] else {
                throw ProbeError("Stage storage changed after owned source deletion")
            }
            count += checked.checks
        }
        try check()
        loaderProofCompleted = true
        return QwenLayerStageLoaderCheckResult(syntheticDType: fixture.syntheticDType, wrapped: fixture.wrapped,
            fp16LayerMetadata: fixture.fp16FFNMetadata, fp16MetadataTensorCount: fixture.fixture.fp16MetadataTensorCount,
            tensorChecks: expectedRecords.reduce(0) { $0 + $1.count }, tensorChecksAfterSourceDeletion: count,
            sourceTensorBytes: sourceBytes, activeTensorBytes: activeBytes, inertTensorBytes: inertBytes,
            receipts: stages.map(\.receipt), badAggregateRejectedStages: badAggregateRejectedStages,
            corruptedSourceRejectedStages: rejected)
    }

}
