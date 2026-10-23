import CryptoKit
import Foundation
import MLXLMCommon
import MLXLMServer
import Testing
@testable import ProviderCore

/// Every OpenRouter capability-test shape through the Super owner's request
/// path as the coordinator relay drives it: inbound decode, native control
/// checks, the service's response-format preparation, the request plan, the
/// pinned template render and the output parser; then a compliant response
/// through that parser, streamed and complete. CPU only.
@Suite("Nemotron Super OpenRouter capability shapes")
struct NemotronSuperOpenRouterCapabilityTests {
    typealias Shape = SuperOpenRouterCapabilityShapes.Shape

    struct Outcome: CustomStringConvertible {
        let shape: Shape
        /// nil: every layer admitted the request.
        let refusal: (layer: String, error: String)?
        var description: String {
            let reasoning = shape.reasoning ? "enabled" : "disabled"
            guard let refusal else { return "| \(shape.name) | \(reasoning) | served | |" }
            return "| \(shape.name) | \(reasoning) | refused | \(refusal.layer): \(refusal.error) |"
        }
    }

    /// The plan `SuperHTTPEngine` builds for a relayed body.
    static func plan(_ shape: Shape) throws -> NemotronSuperRequestPlan {
        let inbound = try ProviderLoop.decodeInboundChatRequest(shape.body)
        var streaming = inbound.request
        streaming.stream = true
        return try NemotronSuperRequestPlan(body: shape.body,
            formatted: OpenAIResponseFormatSupport.preparedRequest(streaming),
            modelID: SuperOpenRouterCapabilityShapes.modelID, trustsSchemaMetadata: true)
    }

    static func probe(_ shape: Shape) throws -> Outcome {
        let template = try #require(Data(base64Encoded: superImagePinnedTemplateBase64,
                                        options: .ignoreUnknownCharacters))
        var layer = "inbound decode"
        do {
            let inbound = try ProviderLoop.decodeInboundChatRequest(shape.body)
            layer = "native controls"
            try ProviderPromptContractPipeline.validateNativeControls(
                inbound.extensions.templateControls.resolvingPromptDate(), modelType: "nemotron_h_omni")
            // The relay forces streaming before the service prepares the request.
            var streaming = inbound.request
            streaming.stream = true
            layer = "service preparation"
            let formatted = try OpenAIResponseFormatSupport.preparedRequest(streaming)
            layer = "request plan"
            let plan = try NemotronSuperRequestPlan(body: shape.body, formatted: formatted,
                modelID: SuperOpenRouterCapabilityShapes.modelID, trustsSchemaMetadata: true)
            layer = "prompt render"
            _ = try plan.textPromptTokens(body: shape.body, templateBytes: template,
                                          tokenizer: SuperVideoTextTokenizer())
            layer = "output parser"
            _ = try NemotronSuperLocalOutput(plan: plan, streaming: true)
            return Outcome(shape: shape, refusal: nil)
        } catch {
            return Outcome(shape: shape, refusal: (layer, String(describing: error)))
        }
    }

    @Test func capturedRequestIsTheConformanceFixture() {
        let digest = SHA256.hash(data: Data(SuperOpenRouterCapabilityShapes.capturedAutoRequest.utf8))
        #expect(digest.map { String(format: "%02x", $0) }.joined()
            == "d63598aad05a4e1dda12a82c119616c490de714f1a51328b39eb598b6229844b")
    }

    @Test func everyCapabilityShapeIsServed() throws {
        let outcomes = try SuperOpenRouterCapabilityShapes.all().map(Self.probe)
        print((["| Shape | Reasoning | Result | Refusing layer |", "|---|---|---|---|"]
            + outcomes.map(\.description)).joined(separator: "\n"))
        for outcome in outcomes {
            #expect(outcome.refusal == nil, "\(outcome)")
        }
    }

    static let call = "<tool_call>\n<function=get_current_weather>\n<parameter=location>\nBoston, MA\n</parameter>\n"
        + "<parameter=unit>\nfahrenheit\n</parameter>\n</function>\n</tool_call>"
    static let reasoning = "The user wants Boston's weather in fahrenheit.</think>\n"

    /// A compliant response for the shape, after any reasoning.
    static func compliantAnswer(_ shape: Shape) -> String {
        switch shape.expectation {
        case .answerOnly: "It is 72°F and sunny in Boston, MA."
        case .call, .jsonOrCall: call
        case .answerOrCall: shape.name == "tool-call-step-5"
            ? "Boston 60°F, Austin 65°F, Denver 70°F and Miami 75°F." : call
        case .jsonObject: #"{"location": "Boston, MA", "temperature": 72}"#
        case .jsonSchema: #"{"location": "Boston, MA", "temperature": 72.5, "conditions": "Sunny"}"#
        }
    }

    /// The owner's parser validates each shape's compliant response, streamed
    /// and complete, with reasoning split off when the request enabled it.
    @Test func compliantResponsesPassTheOwnersParser() throws {
        for shape in try SuperOpenRouterCapabilityShapes.all() {
            let plan = try Self.plan(shape)
            let text = (shape.reasoning ? Self.reasoning : "") + Self.compliantAnswer(shape)
            for streaming in [false, true] {
                var output = try NemotronSuperLocalOutput(plan: plan, streaming: streaming)
                for chunk in Self.chunks(text) { _ = try output.append(chunk) }
                try Self.check(try output.finish().result, shape,
                               label: "\(shape.name) reasoning=\(shape.reasoning) streaming=\(streaming)")
            }
        }
    }

    /// A JSON format with tools: a call needs no JSON answer, an answer must
    /// be JSON, and a forced choice still needs its call.
    @Test func jsonFormatWithToolsValidatesTheAnswerNotTheCall() throws {
        let shapes = try SuperOpenRouterCapabilityShapes.all().filter { !$0.reasoning }
        let auto = try Self.plan(try #require(shapes.first { $0.name == "json-object-with-tools" }))
        for streaming in [false, true] {
            var json = try NemotronSuperLocalOutput(plan: auto, streaming: streaming)
            _ = try json.append(#"{"location": "Boston, MA"}"#)
            #expect(try json.finish().result.content == #"{"location": "Boston, MA"}"#)
            var prose = try NemotronSuperLocalOutput(plan: auto, streaming: streaming)
            _ = try prose.append("It is sunny.")
            #expect(throws: MLXOpenAIServiceError.self) { try prose.finish() }
            var commentary = try NemotronSuperLocalOutput(plan: auto, streaming: streaming)
            _ = try commentary.append("Checking.\n" + Self.call)
            let result = try commentary.finish().result
            #expect(result.calls.map(\.function.name) == ["get_current_weather"])
        }
        let forced = try Self.plan(try #require(shapes.first { $0.name == "json-schema-with-required-tool" }))
        var missing = try NemotronSuperLocalOutput(plan: forced, streaming: false)
        _ = try missing.append(#"{"location": "Boston, MA", "temperature": 1, "conditions": "x"}"#)
        #expect(throws: (any Error).self) { try missing.finish() }
    }

    static func chunks(_ text: String) -> [String] {
        var chunks: [String] = [], current = ""
        for character in text {
            current.append(character)
            if current.count == 7 { chunks.append(current); current = "" }
        }
        return current.isEmpty ? chunks : chunks + [current]
    }

    static func check(_ result: NemotronSuperLocalOutput.Result, _ shape: Shape, label: String) throws {
        let weather = MLXLMCommon.JSONValue.object(["location": .string("Boston, MA"),
                                                     "unit": .string("fahrenheit")])
        switch shape.expectation {
        case .call, .jsonOrCall:
            #expect(result.calls.map(\.function.name) == ["get_current_weather"], "\(label)")
            #expect(result.calls.first.map { .object($0.function.arguments) } == weather, "\(label)")
            // A call turn's framing newline, if any, is all the text it carries.
            #expect(ToolChoiceEnforcementPolicy.isFramingWhitespace(result.content), "\(label)")
        case .answerOrCall where shape.name != "tool-call-step-5":
            #expect(result.calls.map(\.function.name) == ["get_current_weather"], "\(label)")
        case .answerOnly, .answerOrCall:
            #expect(result.calls.isEmpty && !result.content.isEmpty, "\(label)")
        case .jsonObject, .jsonSchema:
            let value = try JSONDecoder().decode(MLXLMCommon.JSONValue.self, from: Data(result.content.utf8))
            guard case .object(let members) = value else {
                Issue.record("\(label): \(result.content)")
                return
            }
            #expect(members["location"] == .string("Boston, MA"), "\(label)")
            #expect(result.calls.isEmpty, "\(label)")
        }
        #expect((result.reasoning != nil) == shape.reasoning, "\(label)")
    }
}
