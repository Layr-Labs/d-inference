// Copyright © 2026 Eigen Labs.
//
// Recursive's Flint serving guide (RecursiveSI/flint sglang/README.md at
// 2a247be0c0aec895ccb0ac7ca92229ec6df37288): `response_format` constrains
// `content`; Flint may first reason in <think>…</think>, and the constraint
// applies to the answer after it. A request with both tools and a response
// format gets only the response format.

import Foundation
import MLXLMCommon
import MLXLMServer

/// Exact-Flint JSON output contract: compiled once per request, enforced by
/// the native constraint and checked again on the completed content.
enum FlintResponseFormat {
    /// `nil` for other families and non-JSON formats. A schema outside the
    /// shared compiled subset fails closed as an invalid request.
    static func resolve(
        _ request: OpenAIChatCompletionRequest, modelType: String?
    ) throws -> JSONAnswerFormat? {
        guard modelType == "flint", let format = request.responseFormat, format.requiresJSONOutput else {
            return nil
        }
        do {
            return try JSONAnswerFormat(format, forbidding: FlintNativeProtocolBoundary.protocolMarkers,
                family: "Flint")
        } catch let error as ToolConstraintSchemaError {
            let detail: String
            switch error {
            case .invalid(let message): detail = "invalid: \(message)"
            case .unsupported(let message): detail = "unsupported: \(message)"
            }
            throw MultiModelBatchSchedulerEngineError.invalidToolPayload("Flint response_format is \(detail)")
        }
    }
}
