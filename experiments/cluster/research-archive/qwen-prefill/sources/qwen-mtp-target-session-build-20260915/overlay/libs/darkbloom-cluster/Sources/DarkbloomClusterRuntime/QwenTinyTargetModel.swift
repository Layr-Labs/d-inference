#if QWEN_TARGET_TINY_FIXTURE
import Foundation
import MLX
import MLXLMCommon
import MLXNN

/// A deterministic fabricated source inventory, never a registered checkpoint.
/// Both actual stage models borrow exactly its globally named parameter arrays.
final class QwenTinyTargetModel {
    let stages: [LoadedQwenLayerStage]
    let sourceTensorCount: Int
    let sourceTensorBytes: Int
    let sourcePayloadSHA256: String
    private init(stages: [LoadedQwenLayerStage], count: Int, bytes: Int, payload: String) {
        self.stages = stages; sourceTensorCount = count; sourceTensorBytes = bytes; sourcePayloadSHA256 = payload
    }

    static func configuration() throws -> Data {
        var object = try JSONSerialization.jsonObject(with: MTPTinyModel.configuration(layers: 8, mtpLayers: 0)) as! [String: Any]
        object["mtplx_mtp"] = ["included": false, "prefix": "mtp.", "block_size": 3]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    static func make(check: () throws -> Void) throws -> QwenTinyTargetModel {
        try check(); try QwenResidentResourceEnvironment.require()
        let configuration = try configuration()
        let plan = try QwenLayerStagePlan(configuration: configuration, ranges: [0..<4, 4..<8])
        let full = try constructQwenModel(configuration)
        let sourceParameters = full.parameters().flattened().sorted { $0.0 < $1.0 }
        let mappings = try plan.parameters(canonicalSourceNames: sourceParameters.map(\.0))
        guard mappings.count == sourceParameters.count,
              sourceParameters.allSatisfy({ $0.1.dtype == .float32 }),
              !full.namedModules().contains(where: { $0.0 == "mtp" || $0.0.hasSuffix(".mtp") }) else {
            throw ProbeError("Tiny full source is not the exact complete F32 target")
        }
        // Check actual constructor sizes BEFORE creating/evaluating values.
        // Four full source-shaped sets conservatively cover full defaults,
        // replacements, compact defaults and transition retention. Two largest
        // leaves cover the serial host construction/hash copies. This is a
        // named constructor allowance, not a whole native workspace bound.
        let rounded = try sourceParameters.map { try QwenResidentResourceEnvironment.allocationBound($0.1.nbytes) }
        let sum = QwenLongPrefillCheckedBytes.sum
        let construction = QwenResidentRequestAllowance(stateBytes: 0, fusionBytes: 0,
            reservedBytes: try sum([sum(rounded), sum(rounded), sum(rounded), sum(rounded),
                rounded.max() ?? 0, rounded.max() ?? 0]))
        try construction.requireLive(); try check()
        let values = sourceParameters.map { name, old -> (String, MLXArray) in
            let salt = name.utf8.reduce(0) { ($0 + Int($1)) % 31 }
            let data = (0..<old.size).map { i -> Float in
                if name.hasSuffix("A_log") { return -1 }
                if name.contains("norm") { return 1 + Float((i + salt) % 5) * 0.02 }
                return Float((i + salt) % 17 - 8) * 0.003
            }
            return (name, MLXArray(data).reshaped(old.shape))
        }
        try full.update(parameters: ModuleParameters.unflattened(values), verify: [.all])
        full.freeze(); eval(full); try check(); try construction.requireLive()
        let source = Dictionary(uniqueKeysWithValues: full.parameters().flattened())
        let fullLayout = modelParameterLayout(full)
        let payloadLines = try source.keys.sorted().map { name -> String in
            let array = source[name]!, bytes = array.asData().data
            try check()
            return "\(name)|\(array.shape)|float32|\(array.nbytes)|\(sha256(bytes))"
        }
        let payload = sha256(Data(payloadLines.joined(separator: "\n").utf8))
        let aggregate = sha256(Data(("fabricated-tiny-global-parameters-v1\n" + payload).utf8))
        let sourceBytes = try sum(source.values.map(\.nbytes))
        var constructed: [(any LanguageModel, QwenStagePreparedInventory)] = []
        for descriptor in plan.stages {
            try construction.requireLive(); try check()
            let model = try constructQwenModel(descriptor.constructionConfiguration)
            let inert = try installQwenStageInertParameters(model: model, stage: descriptor,
                hiddenSize: 64, activationDType: .float32)
            var replacements = Dictionary(uniqueKeysWithValues: model.parameters().flattened())
            var active: [QwenStageActiveTensor] = []
            for mapping in mappings.filter({ $0.stage == descriptor.index }).sorted(by: { $0.localName < $1.localName }) {
                guard let array = source[mapping.sourceName], let old = replacements[mapping.localName],
                      old.shape == array.shape, old.dtype == array.dtype else {
                    throw ProbeError("Tiny global-to-local parameter mapping differs from the actual constructor")
                }
                replacements[mapping.localName] = array
                active.append(.init(sourceName: mapping.sourceName, localName: mapping.localName,
                    shape: array.shape, sourceDType: "float32", loadedDType: "float32", byteCount: array.nbytes))
            }
            let inertNames = Set(inert.flatMap(\.parameters).map(\.localName))
            guard Set(replacements.keys) == Set(active.map(\.localName)).union(inertNames),
                  Set(active.map(\.localName)).isDisjoint(with: inertNames) else {
                throw ProbeError("Tiny stage active/inert inventory does not cover every parameter")
            }
            try model.update(parameters: ModuleParameters.unflattened(replacements.map { ($0.key, $0.value) }
                .sorted { $0.0 < $1.0 }), verify: [.all])
            model.freeze(); eval(model); try check()
            let summary = QwenStageStorageSummary(stageIndex: descriptor.index,
                constructionConfigurationSHA256: sha256(descriptor.constructionConfiguration),
                stagePlanSHA256: descriptor.fingerprint, activeMappingSHA256: sha256(try canonicalJSONData(active)),
                activeParameterLayoutSHA256: qwenStageLayout(active.map { "\($0.localName):\($0.loadedDType):\($0.shape)" }),
                parameterLayoutSHA256: modelParameterLayout(model), loadedTensorBytes: active.reduce(0) { $0 + $1.byteCount },
                activeTensorCount: active.count, inertTensorBytes: inert.flatMap(\.parameters).reduce(0) { $0 + $1.byteCount },
                inertTensorCount: inert.flatMap(\.parameters).count)
            constructed.append((model, .init(active: active, inert: inert, summary: summary)))
        }
        guard try sum(constructed.map { $0.1.summary.loadedTensorBytes }) == sourceBytes,
              constructed.flatMap({ $0.1.active }).map(\.sourceName).sorted() == source.keys.sorted() else {
            throw ProbeError("Tiny two-stage source tensor ownership is not a complete disjoint partition")
        }
        let storage = QwenLayerStageStorageCommitment(schemaVersion: 1, verifiedAggregateSHA256: aggregate,
            sourceConfigurationSHA256: sha256(configuration), planSHA256: plan.fingerprint,
            sourceTensorManifestSHA256: payload, sourceModelTensorBytes: sourceBytes,
            largestSourceTensorBytes: source.values.map(\.nbytes).max()!, sourceTensorCount: source.count,
            canonicalTensorCount: source.count, bf16ConversionEnabled: false, stages: constructed.map { $0.1.summary })
        let storageHash = sha256(try canonicalJSONData(storage))
        let stages = plan.stages.map { descriptor -> LoadedQwenLayerStage in
            let (model, inventory) = constructed[descriptor.index], s = inventory.summary
            let receipt = QwenLayerStageLoadReceipt(schemaVersion: 1, stageIndex: descriptor.index,
                verifiedAggregateSHA256: aggregate, sourceConfigurationSHA256: sha256(configuration),
                constructionConfigurationSHA256: s.constructionConfigurationSHA256, planSHA256: plan.fingerprint,
                stagePlanSHA256: descriptor.fingerprint, sourceTensorManifestSHA256: payload,
                sourceParameterLayoutSHA256: fullLayout, parameterLayoutSHA256: s.parameterLayoutSHA256,
                activeParameterLayoutSHA256: s.activeParameterLayoutSHA256, activeMappingSHA256: s.activeMappingSHA256,
                embeddingActivationDType: "float32", bf16ConversionEnabled: false, sourceModelTensorBytes: sourceBytes,
                loadedTensorBytes: s.loadedTensorBytes, largestHostTensorBytes: source.values.map(\.nbytes).max()!,
                activeTensors: inventory.active, inertModules: inventory.inert, inertTensorBytes: s.inertTensorBytes,
                storageCommitment: storage, storageCommitmentSHA256: storageHash, selectedPayloadReadAccounting: nil)
            return .init(model: model, plan: plan, stageIndex: descriptor.index, receipt: receipt,
                activationDType: .float32, vocabularySize: 128)
        }
        return .init(stages: stages, count: source.count, bytes: sourceBytes, payload: payload)
    }

    func requireStage(_ loaded: LoadedQwenLayerStage) throws {
        guard stages.indices.contains(loaded.stageIndex),
              ObjectIdentifier(loaded.model) == ObjectIdentifier(stages[loaded.stageIndex].model),
              loaded.receipt.storageCommitmentSHA256 == stages[loaded.stageIndex].receipt.storageCommitmentSHA256,
              loaded.plan.originalConfiguration == (try Self.configuration()) else {
            throw ProbeError("Tiny resource authority belongs to a different constructed stage")
        }
    }
}
#endif
