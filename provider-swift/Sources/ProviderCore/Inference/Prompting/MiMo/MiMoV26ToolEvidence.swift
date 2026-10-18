// Copyright © 2026 Eigen Labs.

import MLXLMServer

/// Original Chat tool declarations, kept separately from the fixed-size control
/// refusal capsule. Provider decoding can infer schema types before the loaded
/// model is known; native MiMo must render and enforce the original declaration.
/// This retains typed tools only, never the body, and grants no admission bypass.
struct MiMoV26ToolEvidence: Sendable, Equatable, Decodable {
    private var captured = false
    private var invalid = false
    private var tools: [OpenAITool]?

    private enum CodingKeys: String, CodingKey { case tools }

    init() {}

    init(from decoder: any Decoder) {
        do {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            guard values.contains(.tools), try !values.decodeNil(forKey: .tools) else { return }
            captured = true
            var entries = try values.nestedUnkeyedContainer(forKey: .tools)
            var retained: [OpenAITool] = []
            while !entries.isAtEnd {
                if let tool = try entries.decode(OriginalTool.self).value { retained.append(tool) }
            }
            tools = retained
        } catch {
            captured = true
            invalid = true
        }
    }

    /// Discard only entries the existing ingress repair cannot represent.
    /// Probe structure without reserializing parameter values; malformed retained
    /// function/name declarations must still throw from the actual SDK decoder.
    private struct OriginalTool: Decodable {
        let value: OpenAITool?
        private enum CodingKeys: String, CodingKey { case function, name }

        init(from decoder: any Decoder) throws {
            guard let fields = try? decoder.container(keyedBy: CodingKeys.self) else {
                value = nil
                return
            }
            let functionIsObject = (try? fields.nestedContainer(
                keyedBy: CodingKeys.self, forKey: .function)) != nil
            let nameIsString = (try? fields.decode(String.self, forKey: .name)) != nil
            guard InboundChatNormalization.isRepresentableTool(
                functionIsObject: functionIsObject, nameIsString: nameIsString) else {
                value = nil
                return
            }
            value = try OpenAITool(from: decoder)
        }
    }

    func restoring(
        _ request: OpenAIChatCompletionRequest, modelType: String?
    ) throws -> OpenAIChatCompletionRequest {
        guard modelType == "mimo_v2", captured else { return request }
        guard !invalid else {
            throw MultiModelBatchSchedulerEngineError.invalidToolPayload("MiMo: invalid tool declarations")
        }
        // Only our ingress normalizer may create this marker. Original client
        // declarations never inherit its trust, even on the provider route.
        // Reuse the existing fail-closed schema-position walk and depth limit.
        try ToolConstraintValidation.rejectReservedSchemaMetadata(
            tools, allowInternalSchemaMetadata: false)
        var copy = request
        copy.tools = tools
        return copy
    }
}
