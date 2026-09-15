import Foundation
import MLXLMCommon
import Testing

@testable import ProviderCore

struct FlashNextLifecycleFailure: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

struct FlashNextLifecycleIdentity: Equatable {
    let content: String
    let finish: [String]
    let promptTokens: UInt64
    let completionTokens: UInt64
}

final class FlashNextLifecycleWeakOwners: @unchecked Sendable {
    private let lock = NSLock()
    private weak var container: ModelContainer?
    private weak var target: AnyObject?
    init(container: ModelContainer, target: AnyObject) {
        self.container = container
        self.target = target
    }
    var isAlive: Bool { lock.withLock { container != nil || target != nil } }
}

extension ProviderLoop {
    func flashNextLifecycleOwners(_ modelID: String) async throws -> FlashNextLifecycleWeakOwners {
        let container = try #require(modelSlots[modelID]?.container)
        return await container.perform { context in
            FlashNextLifecycleWeakOwners(container: container, target: context.model)
        }
    }

    func flashNextLifecycleRequestIsRetired(_ requestID: String) -> Bool {
        inflightTasks[requestID] == nil && inflightProfiles[requestID] == nil
            && requestToModel[requestID] == nil && !completedBeforeTaskRegistration.contains(requestID)
    }
}

final class FlashNextLifecycleRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [OutboundMessage] = []
    private let receiver: NodeKeyPair
    init(receiver: NodeKeyPair) { self.receiver = receiver }
    func record(_ message: OutboundMessage) { lock.withLock { messages.append(message) } }

    func output(for requestID: String) throws -> FlashNextLifecycleOutput {
        let snapshot = lock.withLock { messages }
        var output = FlashNextLifecycleOutput()
        for message in snapshot {
            switch message {
            case .inferenceChunk(let id, let plaintext, let encrypted) where id == requestID:
                try #require(plaintext.isEmpty && encrypted != nil, "Response must remain encrypted")
                let data = try receiver.decryptPayload(#require(encrypted))
                try output.consume(data)
            case .inferenceComplete(let id, let usage, _, _, _, _) where id == requestID:
                output.completions += 1
                output.usage = usage
            case .inferenceError(let id, let failure, _) where id == requestID:
                output.failures.append(failure)
            default: break
            }
        }
        return output
    }
}

struct FlashNextLifecycleOutput {
    var content = ""
    var reasoning = ""
    var sawTool = false
    var doneCount = 0
    var finishReasons: [String] = []
    var promptTokens: Int?
    var completionTokens: Int?
    var usage: UsageInfo?
    var completions = 0
    var failures: [InferenceFailure] = []
    var terminalCount: Int { completions + failures.count }

    mutating func consume(_ data: Data) throws {
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") where line.hasPrefix("data: ") {
            let text = String(line.dropFirst(6))
            if text == "[DONE]" { doneCount += 1; continue }
            let object = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            try #require(object["error"] == nil)
            if let value = object["usage"] as? [String: Any] {
                promptTokens = value["prompt_tokens"] as? Int
                completionTokens = value["completion_tokens"] as? Int
            }
            for choice in object["choices"] as? [[String: Any]] ?? [] {
                if let reason = choice["finish_reason"] as? String { finishReasons.append(reason) }
                let delta = choice["delta"] as? [String: Any] ?? [:]
                content += delta["content"] as? String ?? ""
                reasoning += delta["reasoning_content"] as? String ?? ""
                reasoning += delta["reasoning"] as? String ?? ""
                sawTool = sawTool || !(delta["tool_calls"] as? [[String: Any]] ?? []).isEmpty
            }
        }
    }
}
