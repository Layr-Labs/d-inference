import Foundation

/// OpenRouter capability-test request shapes for Nemotron 3.5 Super. Every
/// tool shape starts from the captured OpenRouter tool request (the platform
/// conformance fixture `orIncidentAuto`, kept byte for byte below): the
/// `get_current_weather` declaration with `strict: true`, a closed object,
/// an enum and `reasoning: {"enabled": false}`. The other shapes vary only
/// what each capability test varies: `tool_choice`, the conversation length,
/// `response_format` and `reasoning.enabled`. Synthetic request bodies; no
/// endpoint, credential or model output.
enum SuperOpenRouterCapabilityShapes {
    static let modelID = "nvidia-nemotron-3.5-super"

    /// `orIncidentAuto` from darkbloom-platform
    /// `coordinator/tests/internal/conformance/incident_fixtures.go`, whose
    /// provenance test pins SHA-256 d63598aa…229844b over these bytes.
    static let capturedAutoRequest = #"{"messages":[{"content":"What is the weather like in Boston, MA in fahrenheit?","role":"user"}],"reasoning":{"enabled":false},"stream":true,"tool_choice":"auto","tools":[{"function":{"description":"Get the current weather in a given location","name":"get_current_weather","parameters":{"additionalProperties":false,"properties":{"location":{"description":"The city and state, e.g. San Francisco, CA","type":"string"},"unit":{"enum":["celsius","fahrenheit"],"type":"string"}},"required":["location","unit"],"type":"object"},"strict":true},"type":"function"}]}"#

    struct Shape: Sendable {
        let name: String
        let reasoning: Bool
        let body: Data
        /// What a served response must hold.
        let expectation: Expectation
    }

    enum Expectation: Sendable, Equatable {
        case answerOrCall, answerOnly, call, jsonObject, jsonSchema, jsonOrCall
    }

    static var jsonSchemaFormat: [String: Any] { ["type": "json_schema", "json_schema": [
        "name": "weather_report", "strict": true,
        "schema": ["type": "object", "additionalProperties": false,
                   "required": ["location", "temperature", "conditions"],
                   "properties": ["location": ["type": "string", "description": "City and state"],
                                  "temperature": ["type": "number", "description": "Degrees Fahrenheit"],
                                  "conditions": ["type": "string", "description": "Short description"]]],
    ] as [String: Any]] }

    /// Every capability test, reasoning enabled and disabled, plus the
    /// response-format-with-tools combinations the owner used to refuse.
    static func all() throws -> [Shape] {
        var shapes: [Shape] = []
        for reasoning in [true, false] {
            func shape(_ name: String, _ expectation: Expectation, _ edit: (inout [String: Any]) -> Void) throws {
                var body = try captured()
                body["reasoning"] = ["enabled": reasoning]
                edit(&body)
                shapes.append(Shape(name: name, reasoning: reasoning,
                    body: try JSONSerialization.data(withJSONObject: body), expectation: expectation))
            }
            try shape("tool-call-step-1", .answerOrCall) { $0.removeValue(forKey: "tool_choice") }
            try shape("tool-choice-auto", .answerOrCall) { _ in }
            try shape("tool-choice-none", .answerOnly) { $0["tool_choice"] = "none" }
            try shape("tool-choice-required", .call) { $0["tool_choice"] = "required" }
            try shape("tool-choice-function", .call) {
                $0["tool_choice"] = ["type": "function", "function": ["name": "get_current_weather"]]
            }
            try shape("tool-call-step-5", .answerOrCall) { $0["messages"] = fiveStepConversation(reasoning: reasoning) }
            try shape("response-format-json-object", .jsonObject) {
                $0.removeValue(forKey: "tools"); $0.removeValue(forKey: "tool_choice")
                $0["messages"] = [["role": "user", "content":
                    "Describe the weather in Boston, MA as a JSON object with location and temperature keys."]]
                $0["response_format"] = ["type": "json_object"]
            }
            try shape("structured-output", .jsonSchema) {
                $0.removeValue(forKey: "tools"); $0.removeValue(forKey: "tool_choice")
                $0["messages"] = [["role": "user", "content": "Report the weather in Boston, MA."]]
                $0["response_format"] = jsonSchemaFormat
            }
            try shape("json-object-with-tools", .jsonOrCall) { $0["response_format"] = ["type": "json_object"] }
            try shape("json-schema-with-required-tool", .call) {
                $0["tool_choice"] = "required"
                $0["response_format"] = jsonSchemaFormat
            }
        }
        return shapes
    }

    /// The captured request as a mutable object, with the model the
    /// coordinator resolves and the output bound it injects.
    static func captured() throws -> [String: Any] {
        var body = try JSONSerialization.jsonObject(with: Data(capturedAutoRequest.utf8)) as! [String: Any]
        body["model"] = modelID
        body["max_tokens"] = 4096
        return body
    }

    /// Four answered `get_current_weather` calls; the fifth turn is the model's.
    static func fiveStepConversation(reasoning: Bool) -> [[String: Any]] {
        var messages: [[String: Any]] = [["role": "user", "content":
            "Use the tool to get the weather in Boston MA, Austin TX, Denver CO and Miami FL in fahrenheit, "
            + "one call at a time, then summarize."]]
        for (index, city) in ["Boston, MA", "Austin, TX", "Denver, CO", "Miami, FL"].enumerated() {
            let id = "call_\(index + 1)"
            var assistant: [String: Any] = ["role": "assistant", "content": "", "tool_calls": [[
                "id": id, "type": "function", "function": ["name": "get_current_weather",
                    "arguments": #"{"location":"\#(city)","unit":"fahrenheit"}"#]]]]
            // OpenRouter returns earlier reasoning as `reasoning`.
            if reasoning { assistant["reasoning"] = "Next I need the weather in \(city)." }
            messages.append(assistant)
            messages.append(["role": "tool", "tool_call_id": id,
                             "content": #"{"location":"\#(city)","temperature":\#(60 + index * 5),"unit":"fahrenheit"}"#])
        }
        return messages
    }
}
