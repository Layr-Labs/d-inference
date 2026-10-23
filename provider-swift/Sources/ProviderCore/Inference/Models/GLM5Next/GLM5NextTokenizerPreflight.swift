import Foundation
import MLXLMCommon
import MLXLMServer

enum GLM5NextTokenizerPreflight {
    /// Execute the actual selected tokenizer/template with the same normalized
    /// GLM contexts as serving. Generic template fixtures omit these controls.
    static func validate(_ tokenizer: any MLXLMCommon.Tokenizer, modelID: String) throws {
        let bodies = [
            #"{"messages":[{"role":"user","content":"x"}]}"#,
            #"{"messages":[{"role":"user","content":"x"}],"reasoning_effort":"low","clear_thinking":true}"#,
            #"{"messages":[{"role":"user","content":"x"}],"reasoning_effort":"high","tools":[{"type":"function","function":{"name":"probe","parameters":{"type":"object","properties":{"unit":{"type":"string","enum":["a","b"]}}}}}]}"#,
            #"{"messages":[{"role":"user","content":"x"}],"reasoning_effort":"max","clear_thinking":false}"#,
            #"{"messages":[{"role":"user","content":"x"},{"role":"assistant","content":"","tool_calls":[{"id":"probe-1","type":"function","function":{"name":"probe","arguments":"{\"unit\":\"a\"}"}}]},{"role":"tool","tool_call_id":"probe-1","name":"probe","content":"x"},{"role":"user","content":"x"}],"tools":[{"type":"function","function":{"name":"probe","parameters":{"type":"object","properties":{"unit":{"type":"string"}}}}}]}"#,
        ]
        for body in bodies {
            guard
                var json = try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any]
            else {
                throw GLM5NextManagedLoadError.metadata("internal GLM template probe")
            }
            json["model"] = modelID
            let encoded = try JSONSerialization.data(withJSONObject: json)
            let tokens = try ProviderPromptContractPipeline.tokenizeProviderBody(
                encoded,
                tokenizer: tokenizer, modelType: "glm5_next")
            guard !tokens.isEmpty else {
                throw GLM5NextManagedLoadError.metadata("empty GLM template probe")
            }
        }
    }
}
