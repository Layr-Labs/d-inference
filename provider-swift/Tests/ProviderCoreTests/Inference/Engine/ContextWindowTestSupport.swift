import Foundation
import MLXLMCommon
@testable import ProviderCore

// Shared by `LocalDefaultOutputTests`, `LocalContextWindowTests`, `PairContextWindowTests` and the
// tests that pin a slot's context (`Qwen4SupportPolicyTests`, `Bonsai9BContextTests`,
// `FlintContextAdmissionTests`, `ServingPerformanceProfileTests`, `GLM5NextManagedLoadTests`).

/// The words a client is refused with when a prompt alone fills a single Mac
/// slot's window of `contextTokens` (its advertised context, else its model's),
/// or the context a pair serves.
func windowRefusalWords(_ contextTokens: Int) -> String {
    "The prompt fills this model's context window of \(contextTokens) tokens, leaving no room for an answer. "
        + "Shorten the prompt or start a new conversation."
}

/// The words of the memory 503, on one Mac and on a pair: a request the
/// memory can't hold now.
let memoryRefusalWords = "This Mac's memory can't hold this request right now. Lower max_tokens or shorten the prompt "
    + "(or send less media), or retry when this Mac's other requests finish."

/// That refusal as the bridge throws it.
func windowRefusal(_ contextTokens: Int) -> MultiModelBatchSchedulerEngineError {
    .promptExceedsContext(windowRefusalWords(contextTokens))
}

/// That refusal in-band, as a nonthrowing submission yields it.
func windowRefusalMarker(_ contextTokens: Int) -> String {
    "prompt_exceeds_context: " + windowRefusalWords(contextTokens)
}

/// A 256 GiB Mac with nothing else resident: its memory holds every request.
func roomyKVBudget() -> GlobalKVCacheBudget {
    GlobalKVCacheBudget(memorySnapshot: {
        .init(total: 256 << 30, active: 0, cache: 0, systemAvailable: 256 << 30)
    })
}

/// No tensors or token generation: records the output each admitted request
/// asks for, and its token constraint's budget when it has one.
final class OutputRecordingEngine: CBv2Engine, @unchecked Sendable {
    private let lock = NSLock()
    private var outputs: [Int] = []
    private var constraintBudgets: [Int] = []
    var submittedOutputs: [Int] { lock.withLock { outputs } }
    var submittedConstraintBudgets: [Int] { lock.withLock { constraintBudgets } }
    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        // As EngineV2 admits: a token constraint shares the request's budget.
        if let constraint = request.tokenConstraint, constraint.maxTokens != request.maxTokens {
            throw CBv2SchedulerError.tokenConstraintBudgetMismatch(
                request: request.maxTokens, constraint: constraint.maxTokens)
        }
        lock.withLock {
            outputs.append(request.maxTokens)
            if let constraint = request.tokenConstraint { constraintBudgets.append(constraint.maxTokens) }
        }
        return AsyncStream { $0.finish() }
    }
    func cancel(_ id: CBv2RequestID) {}
    func capacity() -> CBv2CapacitySnapshot {
        .init(activeRequests: 0, waitingRequests: 0, kvBytesInUse: 0, kvBytesCapacity: 0, activeTokens: 0)
    }
    func shutdown() async {}
}

/// A paged slot's engine that can never hold the request: its own admission
/// refuses every submission, as `EngineV2.requireRequestCanEverFit` does when a
/// request needs more KV than the slot's grant. A paged slot takes no bridge
/// reservation, so this is its only memory refusal.
final class NeverFitsEngine: CBv2Engine, @unchecked Sendable {
    private let lock = NSLock()
    private var attempts = 0
    var submissions: Int { lock.withLock { attempts } }
    func submit(_ request: CBv2Request) throws -> AsyncStream<CBv2Event> {
        lock.withLock { attempts += 1 }
        throw CBv2KVError.capacityExhausted(needed: 40_000_000, available: 10_000_000)
    }
    func cancel(_ id: CBv2RequestID) {}
    func capacity() -> CBv2CapacitySnapshot {
        .init(activeRequests: 0, waitingRequests: 0, kvBytesInUse: 0, kvBytesCapacity: 0, activeTokens: 0)
    }
    func shutdown() async {}
}

/// Renders every conversation to `count` tokens.
struct FixedLengthTokenizer: MLXLMCommon.Tokenizer {
    var count = 1
    func encode(text: String, addSpecialTokens: Bool) -> [Int] { Array(repeating: 1, count: count) }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { "" }
    func convertTokenToId(_ token: String) -> Int? { nil }
    func convertIdToToken(_ id: Int) -> String? { nil }
    var bosToken: String? { nil }; var eosToken: String? { nil }; var unknownToken: String? { nil }
    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?) throws -> [Int] { Array(repeating: 1, count: count) }
}
