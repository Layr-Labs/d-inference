import Foundation

/// Model-independent setup liveness request. Family defaults remain authoritative.
enum ClusterSetupProbeRequest {
    static func body(model: String, text: String, maxTokens: Int) -> [String: Any] {
        ["model": model, "messages": [["role": "user", "content": text]],
         "max_tokens": maxTokens, "stream": true, "temperature": 0,
         "stream_options": ["include_usage": true]]
    }
}
