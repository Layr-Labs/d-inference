import Foundation
import CoreFoundation
@testable import ProviderCore

struct RotationHTTPReceipt: Codable {
    let requestOrdinal: Int
    let epoch: UUID
    let status: Int
    let promptTokens: Int
    let completionTokens: Int
    let content: String
    let finishReason: String
    let done: Bool
}

enum RotationHTTP {
    static func complete(port: UInt16, model: String, ordinal: Int, epoch: UUID) async throws -> RotationHTTPReceipt {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!)
        request.httpMethod = "POST"; request.timeoutInterval = 3
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model, "messages": [["role": "user", "content": "request \(ordinal)"]],
            "stream": true, "max_tokens": 2, "temperature": 0, "enable_thinking": false,
            "stream_options": ["include_usage": true]])
        let (bytes, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw RotationCheckError(message: "No actual HTTP response") }
        try rotationRequire(response.statusCode == 200 && bytes.count <= 65_536, "Request failed or output exceeded cap")
        let text = String(decoding: bytes, as: UTF8.self)
        var content = "", reason: String?, usage: (Int, Int)?, done = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.hasPrefix("data: ") else { continue }
            let data = line.dropFirst(6).trimmingCharacters(in: .whitespacesAndNewlines)
            try rotationRequire(!done, "SSE output after DONE")
            if data == "[DONE]" { done = true; continue }
            guard let object = try JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any],
                  object["error"] == nil, let choices = object["choices"] as? [[String: Any]] else {
                throw RotationCheckError(message: "Malformed or failed SSE")
            }
            for choice in choices {
                if let delta = choice["delta"] as? [String: Any], let piece = delta["content"] as? String { content += piece }
                if let next = choice["finish_reason"] as? String {
                    try rotationRequire(reason == nil, "Repeated finish reason")
                    reason = next
                }
            }
            if let counts = object["usage"] as? [String: Any] {
                try rotationRequire(usage == nil, "Repeated terminal usage")
                usage = (try integer(counts["prompt_tokens"]), try integer(counts["completion_tokens"]))
            }
        }
        try rotationRequire(done && reason == "length" && usage?.0 == 3 && usage?.1 == 2 && content == "t9t10",
                            "HTTP token stream, actual usage or terminal differs")
        return .init(requestOrdinal: ordinal, epoch: epoch, status: response.statusCode,
                     promptTokens: 3, completionTokens: 2, content: content, finishReason: "length", done: done)
    }

    static func health(port: UInt16) async throws {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/health")!)
        request.timeoutInterval = 2
        let (_, response) = try await URLSession.shared.data(for: request)
        try rotationRequire((response as? HTTPURLResponse)?.statusCode == 200, "Listener was lost during rotation")
    }

    private static func integer(_ value: Any?) throws -> Int {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue == Double(number.intValue) else { throw RotationCheckError(message: "Usage is not an integer") }
        return number.intValue
    }
}
