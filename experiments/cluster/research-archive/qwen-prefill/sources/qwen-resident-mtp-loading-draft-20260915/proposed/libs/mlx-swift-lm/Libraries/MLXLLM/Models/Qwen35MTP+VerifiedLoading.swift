import Foundation
import MLX
import MLXLMCommon
import MLXNN

extension Qwen35InlineMTPAssistant {
    /// Common lazy constructor/quantization from the existing local loader.
    /// No checkpoint IO or parameter evaluation occurs in this helper.
    static func preparedAssistant(metadata: Qwen35InlineMTPMetadata,
        target: Qwen35TextModel, parameterNames: Set<String>,
        verificationMode: CBv2MTPVerificationMode?, inputEmbedding: Embedding? = nil
    ) throws -> Qwen35InlineMTPAssistant {
        let assistant = Qwen35InlineMTPAssistant(
            configuration: metadata.textConfiguration,
            blockSize: metadata.blockSize, target: target,
            verificationMode: verificationMode, inputEmbedding: inputEmbedding)
        let scaledPaths = Set(parameterNames.compactMap { key -> String? in
            guard key.hasSuffix(".scales") else { return nil }
            return String(key.dropLast(".scales".count))
        })
        for path in scaledPaths where metadata.resolvedQuantization(for: path) == nil {
            throw Qwen35InlineMTPError.missingQuantization(path)
        }
        if !scaledPaths.isEmpty {
            quantize(model: assistant.mtp) { path, _ in
                guard scaledPaths.contains(path) else { return nil }
                return metadata.resolvedQuantization(for: path)?.asTuple
            }
        }
        return assistant
    }

    /// Native-library seam for a verified descriptor owner. It owns an explicit
    /// input-embedding replica but reuses the bound target's final norm/head.
    /// The caller must admit all storage and return an evaluated, owned tensor
    /// from every read. No file, global attachment flag, cache or generation
    /// state is created here. Failure publishes no assistant.
    @_spi(Cluster) public static func loadVerifiedInline(
        configuration: Data, target: any LanguageModel, inputEmbedding: Embedding,
        parameterNames: Set<String>, verificationMode: CBv2MTPVerificationMode,
        read: (String, [Int], DType) throws -> MLXArray,
        check: () throws -> Void
    ) throws -> Qwen35InlineMTPAssistant {
        guard !configuration.isEmpty, configuration.count <= 1_048_576 else {
            throw Qwen35InlineMTPError.invalidConfiguration("bounded configuration required")
        }
        let target = try qwen35TextTarget(target)
        let metadata = try parseMetadata(configuration)
        try validate(metadata.textConfiguration, against: target.configuration)
        guard metadata.prefix == "mtp.", !target.hasMTPHead,
              inputEmbedding.shape.0 == target.vocabularySize,
              inputEmbedding.shape.1 == target.configuration.hiddenSize else {
            throw Qwen35InlineMTPError.invalidConfiguration("inline head or explicit embedding differs")
        }
        let resolved = resolvedVerificationMode(requested: verificationMode,
            forceSerialEnvironment: forceSerialVerification)
        guard resolved != .rectangularExact || target.model.exactTargetVerify else {
            throw Qwen35InlineMTPError.invalidConfiguration("exact verification requires exact target arithmetic")
        }
        let assistant = try preparedAssistant(metadata: metadata, target: target,
            parameterNames: parameterNames, verificationMode: verificationMode,
            inputEmbedding: inputEmbedding)
        let expected = Dictionary(uniqueKeysWithValues: assistant.mtp.parameters().flattened().map {
            ($0.0, (shape: $0.1.shape, dtype: $0.1.dtype))
        })
        guard Set(expected.keys) == parameterNames else {
            throw Qwen35InlineMTPError.invalidWeightIndex("head descriptors do not cover constructed parameters")
        }
        for name in expected.keys.sorted() {
            try check()
            let parameter = expected[name]!
            let value = try read(name, parameter.shape, parameter.dtype)
            guard value.shape == parameter.shape,
                  (value.dtype == .uint32) == (parameter.dtype == .uint32) else {
                throw Qwen35InlineMTPError.invalidWeightIndex("head shape/dtype differs at \(name)")
            }
            try assistant.mtp.update(parameters: ModuleParameters.unflattened([name: value]),
                verify: [.noUnusedKeys, .shapeMismatch])
            try check()
        }
        assistant.mtp.freeze()
        try check()
        return assistant
    }
}
