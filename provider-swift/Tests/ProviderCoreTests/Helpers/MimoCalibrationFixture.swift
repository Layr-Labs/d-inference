import Foundation
import MLXLMCommon

struct MimoCalibrationTokenizer: Tokenizer {
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { Array(repeating: 1, count: text.utf8.count / 4) }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { "example" }
    func convertTokenToId(_ token: String) -> Int? { nil }
    func convertIdToToken(_ id: Int) -> String? { nil }
    var bosToken: String? { nil }
    var eosToken: String? { nil }
    var unknownToken: String? { nil }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?) throws -> [Int] {
        [1] + encode(text: messages.first?["content"] as? String ?? "", addSpecialTokens: false) + [2]
    }
}

/// Real native-loop lifecycle with deterministic work intervals. These are
/// synthetic test timings, never MiMo hardware qualification measurements.
final class MimoCalibrationSession: CBv2NativeBlockSession {
    let request: CBv2Request
    let cancellation: CBv2NativeBlockCancellation
    let gate: RecoveryStepGate?
    var prefilled = false
    var generatedTokenCount = 0
    var closed = false
    var retainedBytes: Int { closed ? 0 : 64 }
    var activeTokenCount: Int { request.promptTokens.count + generatedTokenCount }
    init(request: CBv2Request, cancellation: CBv2NativeBlockCancellation, gate: RecoveryStepGate?) {
        self.request = request; self.cancellation = cancellation; self.gate = gate
    }
    func cancel() { closed = true }
    func advanceNative() throws -> CBv2NativeBlockStep {
        if !prefilled {
            gate?.block()
            if cancellation.isCancelled { throw CancellationError() }
            Thread.sleep(forTimeInterval: Double(request.promptTokens.count) / 8_000)
            prefilled = true
            return .prefill(computedTokens: request.promptTokens.count, complete: true)
        }
        if cancellation.isCancelled { throw CancellationError() }
        Thread.sleep(forTimeInterval: 0.005)
        let count = min(4, request.maxTokens - generatedTokenCount)
        generatedTokenCount += count
        return .committed(tokens: Array(repeating: 65, count: count), stopToken: nil,
            finishReason: generatedTokenCount == request.maxTokens ? .length : nil)
    }
}
