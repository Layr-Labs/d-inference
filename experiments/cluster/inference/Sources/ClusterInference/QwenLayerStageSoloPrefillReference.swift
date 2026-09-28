import Foundation

/// CPU-only descriptor produced by the frozen baseline auditor, never by a
/// forward in the timed process. File SHA and native evidence identity are pins.
struct QwenLayerStageSoloPrefillReference {
    static let maximumEncodedBytes = 128 * 1024
    static let kind = "qwen_layer_stage_solo_prefill_reference"
    static let selectionPolicy = "mlx_argmax_all_axes_with_finite_guard_v1"

    struct Source: Codable, Equatable {
        let artifactAggregateSHA256: String
        let sourceConfigurationSHA256: String
        let sourceParameterLayoutSHA256: String
        let planSHA256: String
        let bf16ConversionEnabled: Bool
        let embeddingActivationDType: String
        let sourceModelTensorBytes: Int
        let layerCount: Int
        let vocabularySize: Int
    }
    struct Request: Codable, Equatable {
        let baselineRequestFingerprint: String
        let baselineRecordedRequestFingerprint: String
        let promptCount: Int
        let chunkSize: Int
        let outputCount: Int
        let vocabularySize: Int
        let promptTokenIDsSHA256: String
        let finalFrame: QwenLayerStageFrame
        let committedTokens: Int
    }
    struct StateEntry: Codable, Equatable {
        let globalLayerIndex: Int
        let component: String
        let shape: [Int]
        let dtype: String
        let byteCount: Int
        let sha256: String

        var key: String { "\(globalLayerIndex)|\(component)" }
        var identity: String { "\(key)|\(shape)|\(dtype)|\(byteCount)|\(sha256)" }
    }
    struct State: Codable, Equatable {
        let committedTokens: Int
        let entries: [StateEntry]
        let logicalByteCount: Int
        let fingerprint: String
    }
    struct Logits: Codable, Equatable {
        let shape: [Int]
        let dtype: String
        let byteCount: Int
        let logicalBytesSHA256: String
    }
    struct Selection: Codable, Equatable {
        let policy: String
        let tokenID: Int
        let maximumTieCount: Int
        let allLogitsFinite: Bool
    }
    struct Descriptor: Codable, Equatable {
        let schemaVersion: Int
        let kind: String
        let baselineEvidenceFingerprint: String
        let source: Source
        let request: Request
        let finalState: State
        let finalLogits: Logits
        let selection: Selection
    }

    let fileSHA256: String
    let descriptor: Descriptor

    private init(fileSHA256: String, descriptor: Descriptor) {
        self.fileSHA256 = fileSHA256; self.descriptor = descriptor
    }

    static func decode(_ data: Data, expectedFileSHA256: String,
        expectedBaselineEvidenceFingerprint: String, plan: QwenLayerStagePlan,
        request: QwenLayerStageRecordedRequest
    ) throws -> Self {
        guard !data.isEmpty, data.count <= maximumEncodedBytes,
              qwenStageWireIsSHA256(expectedFileSHA256), sha256(data) == expectedFileSHA256,
              qwenStageWireIsSHA256(expectedBaselineEvidenceFingerprint) else {
            throw ProbeError("Solo reference requires its bounded exact file bytes and baseline evidence pin")
        }
        // Original bytes must have unique keys and integer numeric lexemes.
        // Canonical decoded comparison rejects extra fields at every nesting.
        let object = try QwenLayerStagePrefillWireJSON.object(data, maximumBytes: maximumEncodedBytes)
        let descriptor = try JSONDecoder().decode(Descriptor.self, from: data)
        try QwenLayerStagePrefillWireJSON.requireExact(object, expected: descriptor)
        guard descriptor.baselineEvidenceFingerprint == expectedBaselineEvidenceFingerprint else {
            throw ProbeError("Solo reference has unknown fields or a different native baseline identity")
        }
        let result = Self(fileSHA256: expectedFileSHA256, descriptor: descriptor)
        try result.requireRequest(request, plan: plan)
        return result
    }
}
