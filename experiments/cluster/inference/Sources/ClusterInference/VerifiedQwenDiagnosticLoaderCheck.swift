import Foundation
import MLX
import MLXLMCommon
import MLXNN

/// Reuses the ordinary saved-fixture oracle and its later source deletion.
/// Nothing here runs an extra model forward or changes the direct-loader record.
struct VerifiedQwenDiagnosticLoaderCheck {
    private let model: any LanguageModel
    private let expected: [String: MLXArray]
    private let directory: URL
    private let receipt: VerifiedQwenDiagnosticReceipt
    private let tensorChecks: Int
    private let residentBytes: Int
    private let fp16FFNMetadata: Bool
    private let fp16MetadataTensorCount: Int

    init(baseline: LoadedModel, fixture: LoaderFixture, directory: URL,
         fp16FFNMetadata: Bool) throws {
        guard baseline.family == .qwen35, baseline.feedForwardKind == "dense",
              baseline.partitionPlan == nil,
              fixture.sourcePartsPerTensor.values.allSatisfy({ $0 == 1 }) else {
            throw ProbeError("Verified full-loader fixture requires an ordinary dense Qwen baseline")
        }
        let configuration = baseline.configurationData
        let base = try JSONDecoder().decode(BaseConfiguration.self, from: configuration)
        guard let policy = base.perLayerQuantization else { throw ProbeError("Fixture lacks quantization policy") }
        let candidate = try constructQwenModel(configuration)
        let before = Dictionary(uniqueKeysWithValues: candidate.parameters().flattened())
        let wrongAggregate = (fixture.aggregateSHA256.first == "0" ? "1" : "0")
            + String(fixture.aggregateSHA256.dropFirst())
        var rejected = false
        do {
            _ = try loadVerifiedQwenDiagnostic(model: candidate, directory: directory,
                originalConfiguration: configuration, policy: policy,
                expectedAggregateSHA256: wrongAggregate)
        } catch {
            guard String(describing: error).contains("Checkpoint manifest differs from expected aggregate") else {
                throw ProbeError("Bad aggregate fixture failed for an unexpected reason: \(error)")
            }
            rejected = true
        }
        let after = Dictionary(uniqueKeysWithValues: candidate.parameters().flattened())
        guard rejected, Set(before.keys) == Set(after.keys),
              before.allSatisfy({ after[$0.key] === $0.value }) else {
            throw ProbeError("Bad aggregate was accepted or changed model parameter handles")
        }
        let receipt = try loadVerifiedQwenDiagnostic(model: candidate, directory: directory,
            originalConfiguration: configuration, policy: policy,
            expectedAggregateSHA256: fixture.aggregateSHA256)
        let expected = Dictionary(uniqueKeysWithValues: baseline.model.parameters().flattened())
        let checked = try checkLoaderTensorStorage(candidate, expected: expected,
            phase: "verified full load versus ordinary saved baseline")
        let total = fixture.parameters.values.reduce(0) { $0 + $1.nbytes }
        let largest = fixture.parameters.values.map(\.nbytes).max()!
        guard receipt.schemaVersion == 1, receipt.verifiedAggregateSHA256 == fixture.aggregateSHA256,
              receipt.configurationSHA256 == baseline.configHash,
              receipt.parameterLayoutSHA256 == baseline.parameterLayoutSHA256,
              receipt.sourceModelTensorBytes == total, receipt.loadedTensorBytes == total,
              receipt.largestHostTensorBytes == largest, receipt.tensorCount == expected.count,
              receipt.tensorCount == fixture.parameters.count,
              receipt.sourceTensorCount == fixture.sourceTensorCount,
              receipt.bf16ConversionEnabled == baseline.bf16ConversionEnabled,
              checked.residentBytes == total else {
            throw ProbeError("Verified full-loader receipt differs from independent fixture accounting")
        }
        if fp16FFNMetadata {
            guard receipt.bf16ConversionEnabled, fixture.fp16MetadataTensorCount > 0,
                  fixture.parameters.filter({ $0.value.dtype == .float16 }).allSatisfy({
                      expected[$0.key]?.dtype == .bfloat16
                  }) else { throw ProbeError("Verified loader fixture did not exercise F16-to-BF16 conversion") }
        }
        self.model = candidate; self.expected = expected; self.directory = directory
        self.receipt = receipt; tensorChecks = checked.checks; residentBytes = checked.residentBytes
        self.fp16FFNMetadata = fp16FFNMetadata
        fp16MetadataTensorCount = fixture.fp16MetadataTensorCount
    }

    func finishAfterSourceDeletion() throws {
        guard !FileManager.default.fileExists(atPath: directory.path) else {
            throw ProbeError("Verified loader source deletion check ran before deletion")
        }
        let checked = try checkLoaderTensorStorage(model, expected: expected,
            phase: "verified full load after source corruption and deletion")
        guard checked.checks == tensorChecks, checked.residentBytes == residentBytes else {
            throw ProbeError("Verified loader storage changed after source deletion")
        }
        try emitJSON(VerifiedQwenDiagnosticLoaderCheckResult(fp16FFNMetadata: fp16FFNMetadata,
            fp16MetadataTensorCount: fp16MetadataTensorCount, tensorChecks: tensorChecks,
            tensorChecksAfterSourceDeletion: checked.checks, residentTensorBytes: residentBytes,
            receipt: receipt))
    }
}

private struct VerifiedQwenDiagnosticLoaderCheckResult: Encodable {
    let kind = "verified_qwen_diagnostic_loader_check"
    let fp16FFNMetadata: Bool
    let fp16MetadataTensorCount: Int
    let tensorChecks: Int
    let tensorChecksAfterSourceDeletion: Int
    let residentTensorBytes: Int
    let receipt: VerifiedQwenDiagnosticReceipt
    let allParameterShapesDTypesAndBytesMatchOrdinary = true
    let independentCompactZeroOffsetBuffers = true
    let badAggregateRejectedWithoutParameterMutation = true
    let sourceFilesCorruptedAndDeleted = true
    let modelForwardCompared = false
}
