import Foundation
import CoreFoundation
import CryptoKit

/// Pure pre-load admission, not proof that an artifact has been read/verified.
/// Root's loader must independently verify the actual artifact aggregate later.
enum QwenRegistered9BLongPrefillAdmission {
    static let name = "registered_qwen35_9b_8192_512_bf16_v1"
    static let expectedConfigurationSHA256 = "c8e767de4953e58352fbc1acbf6615329075ed02fe16a36b8065714d85ee4423"
    static let expectedArtifactAggregateSHA256 = "127de76b4ef82b7aaa0acaac0ee31c784cff066eda64291f521f051469b7c24b"
    static let expectedNamedTensorBytes = 745_345_056
    static let namedTensorByteCeiling = 768 * 1024 * 1024

    struct Receipt: Encodable {
        let qualification: String
        let sourceConfigurationSHA256: String, expectedArtifactAggregateSHA256: String
        let promptCount: Int, chunkSize: Int, outputCount: Int, frameCount: Int
        let batchSize: Int, teacherTokenCount: Int, requiredNativeDType: String
        let bf16ConversionRequired: Bool, geometry: QwenLongPrefillBudgetGeometry
        let budget: QwenLongPrefillTensorBudget, namedTensorByteCeiling: Int
        let exactConfigurationBytesMatched = true
        let actualArtifactVerificationStillRequired = true
        let actualNativeDTypeVerificationStillRequired = true
        let actualPromptBytesMustBeSeparatelyPinned = true
        let independentOSResourceAdmissionStillRequired = true
        let numericalOrPerformanceQualificationEstablished = false
        let wholeProcessMemorySafetyEstablished = false
    }

    static func admit(configuration: Data, expectedArtifactAggregateSHA256 artifact: String,
                      promptCount: Int, chunkSize: Int, outputCount: Int,
                      batchSize: Int, teacherTokenCount: Int,
                      nativeDType: String, bf16ConversionEnabled: Bool) throws -> Receipt {
        guard !configuration.isEmpty, configuration.count <= 1_048_576,
              artifact == expectedArtifactAggregateSHA256,
              promptCount == 8192, chunkSize == 512, outputCount == 1,
              batchSize == 1, teacherTokenCount == 0,
              nativeDType == "bfloat16", bf16ConversionEnabled else {
            throw QwenLongPrefillBudgetError.invalid("Registered long-prefill requires exact pinned9B8192/512/1 BF16 admission")
        }
        let configSHA = SHA256.hash(data: configuration).map { String(format: "%02x", $0) }.joined()
        guard configSHA == expectedConfigurationSHA256 else {
            throw QwenLongPrefillBudgetError.invalid("Registered retained configuration bytes differ")
        }
        // Exact bytes were already admitted; Foundation normalization cannot
        // substitute another schema/number spelling under this fixed SHA.
        guard let root = try JSONSerialization.jsonObject(with: configuration) as? [String: Any],
              root["model_type"] as? String == "qwen3_5",
              let text = root["text_config"] as? [String: Any] else {
            throw QwenLongPrefillBudgetError.invalid("Registered Qwen wrapper is missing")
        }
        func n(_ key: String) throws -> Int {
            guard let value = text[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                  !["f", "d"].contains(String(cString: value.objCType)), let result = value as? Int else {
                throw QwenLongPrefillBudgetError.invalid("Registered configuration requires integer " + key)
            }
            return result
        }
        let g = try QwenLongPrefillBudgetGeometry(layers: n("num_hidden_layers"),
            fullAttentionInterval: n("full_attention_interval"), hiddenSize: n("hidden_size"),
            queryHeads: n("num_attention_heads"), kvHeads: n("num_key_value_heads"), headDimension: n("head_dim"),
            linearKeyHeads: n("linear_num_key_heads"), linearValueHeads: n("linear_num_value_heads"),
            linearKeyDimension: n("linear_key_head_dim"), linearValueDimension: n("linear_value_head_dim"),
            convolutionKernel: n("linear_conv_kernel_dim"))
        let maximumTokens = try QwenLongPrefillCheckedBytes.sum([promptCount, outputCount])
        let vocabulary = try n("vocab_size")
        let declaredContext = try n("max_position_embeddings")
        guard vocabulary == 248320, maximumTokens <= min(declaredContext, 32768) else {
            throw QwenLongPrefillBudgetError.invalid("Registered context/vocabulary differs")
        }
        let budget = try QwenLongPrefillTensorBudget.estimate(geometry: g,
            maximumTokens: maximumTokens, chunkSize: chunkSize)
        guard budget.conservativeStateAndBoundaryBytes == expectedNamedTensorBytes,
              budget.conservativeStateAndBoundaryBytes <= namedTensorByteCeiling else {
            throw QwenLongPrefillBudgetError.invalid("Registered named-tensor estimate differs or exceeds its separate ceiling")
        }
        return .init(qualification: name, sourceConfigurationSHA256: configSHA,
            expectedArtifactAggregateSHA256: artifact, promptCount: promptCount, chunkSize: chunkSize,
            outputCount: outputCount, frameCount: promptCount / chunkSize, batchSize: batchSize,
            teacherTokenCount: teacherTokenCount, requiredNativeDType: nativeDType,
            bf16ConversionRequired: true, geometry: g, budget: budget, namedTensorByteCeiling: namedTensorByteCeiling)
    }
}
