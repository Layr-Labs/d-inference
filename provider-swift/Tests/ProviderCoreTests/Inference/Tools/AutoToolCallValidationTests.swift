import Foundation
import MLXLMCommon
import MLXLMServer
import Testing

@testable import ProviderCore

private typealias ArgumentValue = MLXLMCommon.JSONValue

/// `tool_choice: auto` returns the model's calls as generated unless a
/// declared function sets `strict: true`; strict and forced choices stay
/// validated, and every refusal names the check it failed.
@Suite("Automatic tool-call validation")
struct AutoToolCallValidationTests {
    /// `value` and `note` declare no type: JSON Schema accepts any value
    /// there. The ingress normalizer still fills in `type: "string"` for the
    /// chat templates.
    private static func body(strict: Bool, choice: String? = nil, parallel: Bool? = nil) -> Data {
        let strictField = strict ? #","strict":true"# : ""
        var fields = [
            #""model":"gpt-oss-20b","messages":[{"role":"user","content":"Store it."}]"#,
            #""tools":[{"type":"function","function":{"name":"set_value"\#(strictField),"parameters":{"type":"object","#
                + #""properties":{"value":{"description":"Any JSON value"},"note":{"title":"Note"},"#
                + #""count":{"type":"integer"}},"required":["value"]}}}]"#,
        ]
        if let choice { fields.append(#""tool_choice":"# + choice) }
        if let parallel { fields.append(#""parallel_tool_calls":\#(parallel)"#) }
        return Data(("{" + fields.joined(separator: ",") + "}").utf8)
    }

    /// The production ingress: normalized request, the caller's declarations
    /// beside it.
    private static func prepared(_ body: Data, modelType: String = "gpt_oss") throws
        -> ToolChoicePromptPolicy.Prepared
    {
        let inbound = try ProviderLoop.decodeInboundChatRequest(body)
        var prepared = try ToolChoicePromptPolicy.prepare(inbound.request, modelType: modelType)
        prepared.declaredTools = inbound.extensions.templateControls.declaredTools
        return prepared
    }

    private static func call(_ name: String = "set_value", _ arguments: [String: ArgumentValue]) -> ToolCall {
        ToolCall(function: .init(name: name, arguments: arguments))
    }

    private static func check(of body: () throws -> Void) -> ToolNoncomplianceCheck? {
        do {
            try body()
            return nil
        } catch {
            return classifyToolNoncomplianceCheck(error) ?? .other
        }
    }

    // MARK: - Types the normalizer inferred

    @Test func theNormalizerStillFillsInARenderType() throws {
        let request = try ProviderLoop.decodeOpenAIRequest(Self.body(strict: true))
        guard case .object(let parameters)? = request.tools?.first?.function.parameters,
            case .object(let properties)? = parameters["properties"],
            case .object(let value)? = properties["value"]
        else { Issue.record("no normalized parameters"); return }
        #expect(value["type"] == .string("string"))
    }

    @Test(arguments: [
        ArgumentValue.int(42), .double(2.5), .bool(true), .null, .object(["a": .int(1)]),
        .array([.int(1), .string("b")]), .string("text"),
    ])
    func aTypelessPropertyAcceptsAnyValueUnderStrict(value: ArgumentValue) throws {
        let prepared = try Self.prepared(Self.body(strict: true))
        try ToolConstraintValidation.validate(
            [Self.call(["value": value, "note": value])], prepared: prepared)
    }

    @Test func aDeclaredTypeIsStillEnforcedUnderStrict() throws {
        let prepared = try Self.prepared(Self.body(strict: true))
        #expect(Self.check {
            try ToolConstraintValidation.validate(
                [Self.call(["value": .int(1), "count": .string("three")])], prepared: prepared)
        } == .schema)
        #expect(Self.check {
            try ToolConstraintValidation.validate([Self.call(["note": .string("no value")])], prepared: prepared)
        } == .schema)
    }

    // MARK: - auto without strict

    @Test func autoWithoutStrictReturnsCallsAsGenerated() throws {
        let prepared = try Self.prepared(Self.body(strict: false))
        try ToolConstraintValidation.validate([Self.call(["value": .object(["a": .int(1)])])], prepared: prepared)
        // Off-schema arguments and an undeclared function pass unchanged.
        try ToolConstraintValidation.validate([Self.call(["count": .string("three")])], prepared: prepared)
        try ToolConstraintValidation.validate([Self.call("delete_everything", ["path": .string("/")])],
            prepared: prepared)
    }

    @Test func strictAutoRefusesAnUndeclaredFunction() throws {
        let prepared = try Self.prepared(Self.body(strict: true))
        #expect(Self.check {
            try ToolConstraintValidation.validate([Self.call("delete_everything", [:])], prepared: prepared)
        } == .undeclaredName)
    }

    /// A call is never returned to a client that declared no tools, and
    /// `parallel_tool_calls: false` still allows one call.
    @Test func autoKeepsItsOtherLimits() throws {
        let none = try ToolChoicePromptPolicy.prepare(
            ProviderLoop.decodeOpenAIRequest(Data(
                #"{"model":"gpt-oss-20b","messages":[{"role":"user","content":"Hi"}]}"#.utf8)),
            modelType: "gpt_oss")
        #expect(Self.check {
            try ToolConstraintValidation.validate([Self.call(["value": .int(1)])], prepared: none)
        } == .undeclaredName)
        let single = try Self.prepared(Self.body(strict: false, parallel: false))
        #expect(Self.check {
            try ToolConstraintValidation.validate(
                [Self.call(["value": .int(1)]), Self.call(["value": .int(2)])], prepared: single)
        } == .parallel)
    }

    /// Required and named choices keep their fail-closed validation.
    @Test func forcedChoicesStayValidated() throws {
        for choice in [#""required""#, #"{"type":"function","function":{"name":"set_value"}}"#] {
            let prepared = try Self.prepared(Self.body(strict: false, choice: choice), modelType: "qwen3_5")
            #expect(Self.check {
                try ToolConstraintValidation.validate([Self.call(["count": .int(1)])], prepared: prepared)
            } == .schema, "\(choice)")
            #expect(Self.check {
                try ToolConstraintValidation.validate([], prepared: prepared)
            } == .forcedChoice, "\(choice)")
        }
    }

    // MARK: - Which check failed

    @Test func everyToolRefusalNamesItsCheck() {
        let cases: [(Error, ToolNoncomplianceCheck)] = [
            (MultiModelBatchSchedulerEngineError.toolChoiceViolation("model emitted an undeclared tool call"),
             .undeclaredName),
            (MultiModelBatchSchedulerEngineError.toolChoiceViolation(
                "tool call arguments do not satisfy the declared schema"), .schema),
            (MultiModelBatchSchedulerEngineError.toolChoiceViolation("streamed tool call output was malformed"),
             .malformed),
            (MultiModelBatchSchedulerEngineError.toolChoiceViolation("streamed tool call output was diverged"),
             .diverged),
            (MultiModelBatchSchedulerEngineError.toolChoiceViolation(
                "streamed tool call output was unterminated"), .unterminated),
            (MultiModelBatchSchedulerEngineError.toolChoiceViolation(
                "parallel tool calls are disabled for this request"), .parallel),
            (MLXOpenAIServiceError.multipleToolCallsNotAllowed, .parallel),
            (MLXOpenAIServiceError.invalidResponseFormatOutput("x"), .responseFormat),
            (MultiModelBatchSchedulerEngineError.toolChoiceViolation("tool_choice none prohibited a tool call"),
             .forcedChoice),
            (MultiModelBatchSchedulerEngineError.toolChoiceViolation("model did not emit the required tool call"),
             .forcedChoice),
            (MultiModelBatchSchedulerEngineError.toolChoiceViolation("model did not emit the named tool call"),
             .forcedChoice),
            (MultiModelBatchSchedulerEngineError.toolChoiceViolation(
                "forced tool_choice produced visible text before a validated call"), .forcedChoice),
            (MultiModelBatchSchedulerEngineError.toolChoiceViolation("native GLM tool output is invalid"),
             .nativeOutput),
            (MultiModelBatchSchedulerEngineError.toolChoiceViolation(
                "native reasoning output is disabled for this request"), .nativeOutput),
            (MultiModelBatchSchedulerEngineError.toolChoiceViolation("native tool output is malformed"),
             .nativeOutput),
            (MultiModelBatchSchedulerEngineError.fromSchedulerMessage("tool_constraint_impossible_state"), .other),
        ]
        for (error, expected) in cases {
            #expect(classifyToolNoncomplianceCheck(error) == expected, "\(error)")
            let failure = ProviderLoop.sanitizedInferenceFailure(from: error, phase: .generation)
            #expect(failure.errorReason == .toolNoncompliance && failure.toolCheck == expected, "\(error)")
        }
        let others: [Error] = [
            MultiModelBatchSchedulerEngineError.generationFailed("model emitted an undeclared tool call"),
            MLXOpenAIServiceError.responseFormatCutOffByMaxTokens, CancellationError(),
        ]
        for error in others {
            #expect(classifyToolNoncomplianceCheck(error) == nil, "\(error)")
            #expect(ProviderLoop.sanitizedInferenceFailure(from: error, phase: .generation).toolCheck == nil)
        }
    }

    @Test func theCheckRidesTheErrorFrameAndTheLocalLog() throws {
        func frame(_ check: ToolNoncomplianceCheck?) throws -> [String: Any] {
            let failure = InferenceFailure(code: .generationFailure, statusCode: 422,
                errorReason: check == nil ? nil : .toolNoncompliance, toolCheck: check)
            let data = try ProviderProtocolCodec.encodeProviderMessage(
                .inferenceError(.init(requestId: "r", failure: failure)))
            return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        #expect(try frame(.schema)["tool_check"] as? String == "schema")
        #expect(try frame(nil)["tool_check"] == nil, "absent otherwise, so legacy frames stay byte-identical")

        let line = LockedLines()
        InferenceFailureLogger(sink: { line.append($0) }).record(requestId: "r", failure: InferenceFailure(
            code: .generationFailure, statusCode: 422, errorReason: .toolNoncompliance, toolCheck: .malformed))
        #expect(line.all.first?.hasSuffix("reason=tool_noncompliance tool_check=malformed") == true)
    }
}

private final class LockedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
}
