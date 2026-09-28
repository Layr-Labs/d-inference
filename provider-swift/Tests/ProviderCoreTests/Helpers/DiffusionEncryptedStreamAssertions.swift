import Foundation
import Testing

@testable import ProviderCore

final class DiffusionEncryptedRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var messages = [OutboundMessage]()
    func record(_ message: OutboundMessage) { lock.withLock { messages.append(message) } }
    private var snapshot: [OutboundMessage] { lock.withLock { messages } }
    func terminalCount(_ id: String) -> Int {
        snapshot.filter {
            switch $0 {
            case .inferenceComplete(let request, _, _, _, _, _), .inferenceError(let request, _, _): request == id
            default: false
            }
        }.count
    }
    func chunks(_ id: String) -> [ProviderMessage.InferenceResponseChunk] {
        snapshot.compactMap {
            guard case .inferenceChunk(let request, let data, let encrypted) = $0, request == id else { return nil }
            return .init(requestId: request, data: data, encryptedData: encrypted)
        }
    }
}

struct DiffusionEncryptedCall {
    var id = "", name = "", arguments = ""
    var history: [String: Any] { ["id": id, "type": "function", "function": ["name": name, "arguments": arguments]] }
}

struct DiffusionEncryptedOutput {
    var content = "", reasoning = ""
    var done = 0, usageCount = 0
    var finishes = [String]()
    var prompt: Int?, completion: Int?
    private var byIndex = [Int: DiffusionEncryptedCall]()
    var calls: [DiffusionEncryptedCall] { byIndex.keys.sorted().compactMap { byIndex[$0] } }

    mutating func consume(_ data: Data) throws {
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") where line.hasPrefix("data: ") {
            let text = String(line.dropFirst(6))
            if text == "[DONE]" { done += 1; continue }
            let object = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            #expect(object["error"] == nil)
            if let usage = object["usage"] as? [String: Any] {
                usageCount += 1
                prompt = usage["prompt_tokens"] as? Int; completion = usage["completion_tokens"] as? Int
            }
            for choice in object["choices"] as? [[String: Any]] ?? [] {
                if let finish = choice["finish_reason"] as? String { finishes.append(finish) }
                let delta = choice["delta"] as? [String: Any] ?? [:]
                content += delta["content"] as? String ?? ""
                reasoning += delta["reasoning_content"] as? String ?? ""
                reasoning += delta["reasoning"] as? String ?? ""
                for fragment in delta["tool_calls"] as? [[String: Any]] ?? [] {
                    let index = try #require(fragment["index"] as? Int)
                    var call = byIndex[index] ?? .init()
                    if let id = fragment["id"] as? String {
                        #expect(call.id.isEmpty || call.id == id); call.id = id
                    }
                    if let type = fragment["type"] as? String { #expect(type == "function") }
                    if let function = fragment["function"] as? [String: Any] {
                        call.name += function["name"] as? String ?? ""
                        call.arguments += function["arguments"] as? String ?? ""
                    }
                    byIndex[index] = call
                }
            }
        }
    }
}
