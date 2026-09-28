import Foundation
import MLX
import MLXNN

/// Independent ordinary-fixture ownership, active buffer and receipt oracle.
enum QwenLayerStageLoaderOracle {
    /// Derive 4+4 ownership directly from ordinary parameter names. This oracle
    /// does not use plan.parameter(s:) or the loader's mapping/selection helper.
    static func expectedMappings(fixture: QwenLayerStageFixture,
        baseline: [String: MLXArray]
    ) throws -> [[QwenStageActiveTensor]] {
        let prefix = fixture.wrapped ? "language_model." : ""
        let layerPrefix = prefix + "model.layers."
        var result = [[QwenStageActiveTensor](), [QwenStageActiveTensor]()]
        for name in baseline.keys.sorted() {
            let index: Int, local: String
            if name.hasPrefix(layerPrefix) {
                let pieces = name.dropFirst(layerPrefix.count).split(separator: ".", omittingEmptySubsequences: false)
                guard let first = pieces.first, let layer = Int(first), (0..<8).contains(layer),
                      String(layer) == String(first), pieces.count > 1 else {
                    throw ProbeError("Ordinary fixture has a malformed layer name")
                }
                index = layer < 4 ? 0 : 1
                local = layerPrefix + String(layer % 4) + "." + pieces.dropFirst().joined(separator: ".")
            } else if name.hasPrefix(prefix + "model.embed_tokens.") { index = 0; local = name }
            else if name == prefix + "model.norm.weight" || name.hasPrefix(prefix + "lm_head.") { index = 1; local = name }
            else { throw ProbeError("Unknown ordinary tiny fixture parameter: \(name)") }
            guard let source = fixture.fixture.parameters[name], let loaded = baseline[name],
                  source.shape == loaded.shape, source.nbytes == loaded.nbytes else {
                throw ProbeError("Saved source and ordinary fixture geometry differ")
            }
            result[index].append(QwenStageActiveTensor(sourceName: name, localName: local, shape: loaded.shape,
                sourceDType: String(describing: source.dtype), loadedDType: String(describing: loaded.dtype), byteCount: loaded.nbytes))
        }
        return result.map { $0.sorted { $0.localName < $1.localName } }
    }

    static func checkStorage(_ stage: LoadedQwenLayerStage, expected: [String: MLXArray],
        phase: String
    ) throws -> (checks: Int, bytes: Int) {
        let actual = Dictionary(uniqueKeysWithValues: stage.model.parameters().flattened())
        var bytes = 0
        for name in expected.keys.sorted() {
            guard let value = actual[name], let reference = expected[name], value.shape == reference.shape,
                  value.dtype == reference.dtype, value.asData().data == reference.asData().data else {
                throw ProbeError("Active stage tensor differs from ordinary source (\(phase)): \(name)")
            }
            guard let buffer = try value.evaluatedBufferInfo(), buffer.isUnique, buffer.dataOffset == 0,
                  buffer.isRowContiguous, buffer.dataElements == value.size, buffer.allocatedBytes >= value.nbytes,
                  buffer.allocatedBytes <= (try Memory.allocationFootprintUpperBound(byteCount: value.nbytes)) else {
                throw ProbeError("Active stage parameter is not uniquely owned and compact (\(phase)): \(name)")
            }
            bytes += value.nbytes
        }
        return (expected.count, bytes)
    }

    static func checkInert(_ stage: LoadedQwenLayerStage, fixture: QwenLayerStageFixture) throws -> Int {
        let prefix = fixture.wrapped ? "language_model." : ""
        let shapeByPath = stage.stageIndex == 0
            ? [prefix + "model.norm": [128], prefix + "lm_head": [1, 128]]
            : [prefix + "model.embed_tokens": [1, 128]]
        let actual = Dictionary(uniqueKeysWithValues: stage.model.parameters().flattened())
        let inertNames = Set(shapeByPath.keys.map { $0 + ".weight" })
        let activeNames = Set(stage.receipt.activeTensors.map(\.localName))
        guard Set(stage.receipt.inertModules.map(\.path)) == Set(shapeByPath.keys),
              Set(actual.keys) == activeNames.union(inertNames), activeNames.isDisjoint(with: inertNames),
              stage.receipt.inertModules.count == shapeByPath.count else {
            throw ProbeError("Compact stage active/inert inventories are not disjoint and complete")
        }
        var bytes = 0
        for entry in stage.receipt.inertModules {
            let name = entry.path + ".weight"
            guard let value = actual[name], value.shape == shapeByPath[entry.path],
                  value.dtype == stage.activationDType, entry.parameters.count == 1,
                  entry.parameters[0].localName == name, entry.parameters[0].shape == value.shape,
                  entry.parameters[0].dtype == String(describing: value.dtype),
                  entry.parameters[0].byteCount == value.nbytes,
                  entry.replacementKind == (entry.path == prefix + "model.norm" ? "parameter-only-replacement" : "module-replacement") else {
                throw ProbeError("Inactive stage parameter changed its explicit bounded layout")
            }
            let expectedValue: Float = entry.path == prefix + "model.norm" ? 1 : 0
            guard value.asArray(Float.self).allSatisfy({ $0 == expectedValue }) else {
                throw ProbeError("Inactive stage parameter did not retain its declared ones/zeros")
            }
            bytes += value.nbytes
        }
        return bytes
    }

    static func checkReceipt(_ stage: LoadedQwenLayerStage, fixture: QwenLayerStageFixture,
        records: [QwenStageActiveTensor], sourceBytes: Int, activeBytes: Int, inertBytes: Int
    ) throws {
        let receipt = stage.receipt, plan = fixture.plan.stages[stage.stageIndex]
        let layout = records.map { "\($0.localName):\($0.loadedDType):\($0.shape)" }.sorted().joined(separator: "\n")
        let commitment = receipt.storageCommitment
        guard receipt.schemaVersion == 1, receipt.stageIndex == stage.stageIndex,
              receipt.verifiedAggregateSHA256 == fixture.fixture.aggregateSHA256,
              receipt.sourceConfigurationSHA256 == fixture.baseline.configHash,
              receipt.constructionConfigurationSHA256 == sha256(plan.constructionConfiguration),
              receipt.planSHA256 == fixture.plan.fingerprint, receipt.stagePlanSHA256 == plan.fingerprint,
              receipt.sourceParameterLayoutSHA256 == fixture.baseline.parameterLayoutSHA256,
              receipt.parameterLayoutSHA256 == modelParameterLayout(stage.model),
              receipt.activeParameterLayoutSHA256 == sha256(Data(layout.utf8)),
              receipt.activeMappingSHA256 == sha256(try canonicalJSONData(records)),
              try canonicalJSONData(receipt.activeTensors) == canonicalJSONData(records),
              receipt.embeddingActivationDType == fixture.baseline.embeddingActivationDType,
              receipt.bf16ConversionEnabled == fixture.baseline.bf16ConversionEnabled,
              receipt.sourceModelTensorBytes == sourceBytes, receipt.loadedTensorBytes == activeBytes,
              receipt.largestHostTensorBytes == records.map(\.byteCount).max(), receipt.inertTensorBytes == inertBytes,
              receipt.storageCommitmentSHA256 == sha256(try canonicalJSONData(commitment)),
              commitment.schemaVersion == 1, commitment.verifiedAggregateSHA256 == fixture.fixture.aggregateSHA256,
              commitment.sourceConfigurationSHA256 == fixture.baseline.configHash,
              commitment.planSHA256 == fixture.plan.fingerprint,
              commitment.sourceTensorManifestSHA256 == receipt.sourceTensorManifestSHA256,
              commitment.sourceModelTensorBytes == sourceBytes,
              commitment.largestSourceTensorBytes == fixture.fixture.parameters.values.map(\.nbytes).max(),
              commitment.sourceTensorCount == fixture.fixture.sourceTensorCount, commitment.canonicalTensorCount == 237,
              commitment.bf16ConversionEnabled == fixture.baseline.bf16ConversionEnabled,
              commitment.stages.map(\.stageIndex) == [0, 1], commitment.stages.map(\.activeTensorCount) == [118, 119],
              commitment.stages.reduce(0, { $0 + $1.loadedTensorBytes }) == sourceBytes else {
            throw ProbeError("Stage loader receipt differs from independent ordinary-fixture accounting")
        }
        let summary = commitment.stages[stage.stageIndex]
        guard summary.loadedTensorBytes == activeBytes, summary.inertTensorBytes == inertBytes,
              summary.inertTensorCount == (stage.stageIndex == 0 ? 2 : 1),
              summary.activeMappingSHA256 == receipt.activeMappingSHA256,
              summary.activeParameterLayoutSHA256 == receipt.activeParameterLayoutSHA256,
              summary.parameterLayoutSHA256 == receipt.parameterLayoutSHA256 else {
            throw ProbeError("Stage summary disagrees with the independently checked receipt")
        }
    }

    static func checkUnchangedHandles(_ stages: [LoadedQwenLayerStage], before: [[String: MLXArray]]) throws {
        for (stage, prior) in zip(stages, before) {
            let after = Dictionary(uniqueKeysWithValues: stage.model.parameters().flattened())
            guard Set(prior.keys) == Set(after.keys), prior.allSatisfy({ after[$0.key] === $0.value }) else {
                throw ProbeError("Rejected source load changed an already loaded stage's parameter handles")
            }
        }
    }
}
