import Foundation
import MLX
@testable import MLXLMCommon
import MLXNN

@testable import ProviderCore

/// Each barrier has one consumer. The timeout bounds a failing test; it does
/// not choose event order or poll engine state.
final class CancelledPrefixBarrier: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    func signal() { semaphore.signal() }
    func wait() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let signalled = self.semaphore.wait(timeout: .now() + 10) == .success
                continuation.resume(returning: signalled)
            }
        }
    }
}

struct CancelledPrefixTokenizer: MLXLMCommon.Tokenizer {
    let prompt: [Int]
    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        Array(repeating: 5, count: text.count)
    }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        String(repeating: "a", count: tokenIds.count)
    }
    func convertTokenToId(_ token: String) -> Int? { nil }
    func convertIdToToken(_ id: Int) -> String? { "a" }
    var bosToken: String? { nil }
    var eosToken: String? { nil }
    var unknownToken: String? { nil }
    func applyChatTemplate(
        messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] { prompt }
}

/// The real CBv2 recurrent, paged and complete-checkpoint paths operate on
/// these small deterministic tensors. No model weights or network are used.
final class CancelledPrefixModel: CBv2RecurrentSteppableModel,
    CBv2CompleteCheckpointKVTypeProviding
{
    let kinds = [CBv2LayerKind(
        attention: .full, headDim: 64, kvHeads: 1, queryHeads: 1, modelLayerIndex: 0)]
    let cbv2Capabilities = CBv2ModelCapabilities(
        supportsPrefixReuse: false, supportsRecurrentCheckpointReuse: true,
        supportsPagedKV: true, supportsCompiledDecode: false,
        supportsPackedPrefill: false, supportsMTP: false)
    let cbv2CompleteCheckpointKVDTypes: [DType]? = [.float32]
    let recurrentStateSpec: CBv2RecurrentStateSpec? = .init(layers: [.init(
        modelLayerIndex: 1, convShape: [1, 2, 2], convDType: .float32,
        ssmShape: [1, 2, 2, 2], ssmDType: .float32)])

    func forward(tokens: MLXArray, caches: [CBv2AttendingLayerCache]) -> MLXArray {
        preconditionFailure("fixture requires the recurrent engine path")
    }
    func forward(
        tokens: MLXArray, caches: [CBv2AttendingLayerCache],
        recurrentState: [CBv2RecurrentStateEvaluation]
    ) -> MLXArray {
        let batch = tokens.dim(0), length = tokens.dim(1)
        let kv = MLXArray.ones([batch, 1, length, 64], dtype: .float32)
        for cache in caches {
            _ = cache.updateAndAttend(queries: kv, keys: kv, values: kv, scale: 0.125, sinks: nil)
        }
        for evaluation in recurrentState {
            let previous = evaluation.inputState(modelLayerIndex: 1)
            try! evaluation.stage(
                modelLayerIndex: 1,
                conv: (previous?.conv ?? MLXArray.zeros([1, 2, 2])) + Float(length),
                ssm: (previous?.ssm ?? MLXArray.zeros([1, 2, 2, 2])) + Float(length))
        }
        return broadcast(
            MLXArray([Float(0), 0, 0, 0, 0, 1, 0, 0]).reshaped([1, 1, 8]),
            to: [batch, length, 8])
    }
}

private final class CancelledPrefixContainerModel: Module, LanguageModel {
    func prepare(_ input: LMInput, cache: [KVCache], windowSize: Int?) throws -> PrepareResult {
        .tokens(input.text)
    }
    func newCache(parameters: GenerateParameters?) -> [KVCache] { [] }
}

private struct CancelledPrefixProcessor: UserInputProcessor {
    struct UnexpectedPreparation: Error {}
    func prepare(input: UserInput) async throws -> LMInput { throw UnexpectedPreparation() }
}

func cancelledPrefixContainer(tokenizer: CancelledPrefixTokenizer) -> ModelContainer {
    ModelContainer(context: ModelContext(
        configuration: ModelConfiguration(id: "fixture-model"),
        model: CancelledPrefixContainerModel(), processor: CancelledPrefixProcessor(),
        tokenizer: tokenizer))
}

final class CancelledPrefixRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [OutboundMessage] = []
    private var firstDecision: String?
    private var signalledContent = false
    private var deliveredTokens = 0
    private var nativeUsage: CBv2Usage?
    private var encryptedChunks = 0
    private var decodedFrames = 0
    private var deltaKeys: Set<String> = []
    let firstContent = CancelledPrefixBarrier()
    let decision = CancelledPrefixBarrier()
    let terminal = CancelledPrefixBarrier()
    let nativeFinished = CancelledPrefixBarrier()
    let releaseNative = CancelledPrefixBarrier()
    let receiver: NodeKeyPair

    init(receiver: NodeKeyPair) { self.receiver = receiver }

    func record(_ message: OutboundMessage) {
        var contentTokens = 0, ended = false
        var encryptedChunk = false, decodedFrame = false
        var keys: Set<String> = []
        if case .inferenceChunk(_, _, .some) = message { encryptedChunk = true }
        if case .inferenceChunk(_, _, let encrypted?) = message,
            let raw = try? receiver.decryptPayload(encrypted),
            let frame = String(data: raw, encoding: .utf8)
        {
            decodedFrame = true
            for line in frame.split(separator: "\n") where line.hasPrefix("data: ") {
                let json = Data(line.dropFirst(6).utf8)
                guard let body = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
                    let choices = body["choices"] as? [[String: Any]],
                    let delta = choices.first?["delta"] as? [String: Any]
                else { continue }
                keys.formUnion(delta.keys)
                contentTokens += (delta["content"] as? String ?? "").count
                    + (delta["reasoning_content"] as? String ?? "").count
            }
        }
        switch message {
        case .inferenceComplete, .inferenceError: ended = true
        default: break
        }
        let signalContent = lock.withLock {
            messages.append(message)
            deliveredTokens += contentTokens
            encryptedChunks += encryptedChunk ? 1 : 0
            decodedFrames += decodedFrame ? 1 : 0
            deltaKeys.formUnion(keys)
            guard contentTokens > 0, !signalledContent else { return false }
            signalledContent = true
            return true
        }
        if signalContent { firstContent.signal() }
        if ended {
            recordDecision("provider_terminal")
            terminal.signal()
        }
    }

    func recordDecision(_ value: String) {
        let first = lock.withLock {
            guard firstDecision == nil else { return false }
            firstDecision = value
            return true
        }
        if first { decision.signal() }
    }

    func holdNative(_ usage: CBv2Usage) async {
        lock.withLock { nativeUsage = usage }
        nativeFinished.signal()
        _ = await releaseNative.wait()
    }

    var decisionValue: String? { lock.withLock { firstDecision } }
    var observedNativeUsage: CBv2Usage? { lock.withLock { nativeUsage } }
    var deliveredTokenCount: Int { lock.withLock { deliveredTokens } }
    var snapshot: [OutboundMessage] { lock.withLock { messages } }

    /// Bounded fixture diagnostics: classifications and counts only, never
    /// request text, encrypted bytes, or generated key material.
    var diagnosticSummary: String {
        lock.withLock {
            let errors = messages.compactMap { message -> String? in
                guard case .inferenceError(_, let failure, _) = message else { return nil }
                return "\(failure.code.rawValue):\(failure.statusCode)"
                    + ":reason=\(failure.errorReason?.rawValue ?? "nil")"
                    + ":cause=\(failure.terminalCause?.rawValue ?? "nil")"
            }
            return "messages=\(messages.count), encrypted_chunks=\(encryptedChunks), "
                + "decoded_frames=\(decodedFrames), delta_keys=\(deltaKeys.sorted()), "
                + "delivered_tokens=\(deliveredTokens), errors=\(errors.prefix(2)), "
                + "native_prompt=\(nativeUsage?.promptTokens ?? -1), "
                + "native_completion=\(nativeUsage?.completionTokens ?? -1)"
        }
    }
}
