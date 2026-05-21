import CryptoKit
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
#if canImport(os)
import os
#endif

// MARK: - TensorParallelInference
//
// TP path counterpart to EncryptedPipelineInference. Both engines run on
// rank 0; their rank-1 counterparts (TensorParallelServer / EncryptedPipelineServer)
// run on the other Mac. The dispatcher (Parallelism.decide) picks which pair
// to instantiate at cluster-session-ready time.
//
// Key TP-vs-PP difference: in PP, only rank 0's first half of the model
// runs at a time, then rank 1's second half runs, with an activation
// transfer in between. In TP, BOTH ranks run all N layers in parallel,
// with allreduce per layer (handled inside `LlamaModelTP`'s sharded
// linear layers via the underlying `DistributedGroup`). One activation
// transfer per token is replaced by 2N small allreduces per token; the
// per-Mac compute drops by ~½ because each Mac runs half the heads.
//
// On Thunderbolt 5 the allreduce cost is sub-ms and the latency win is
// roughly 2× over PP for single-stream decode.
//
// Protocol (rank 0 → rank 1 per request):
//   1. promptTokens  {uid, tokens, maxTokens}   — begin request, prefill
//   2. stepToken     {uid, token}  × N           — each sampled token fed back
//   3. sessionStop   {uid}                        — EOS / maxTokens / error
//
// All three frame types travel over the encrypted ThunderboltLink; the existing
// AES-256-GCM ClusterFrame.encode/decode path covers them automatically.

// MARK: - TensorParallelConfig

public struct TensorParallelConfig: Sendable {
    public let numLayers: Int
    public let hiddenDim: Int
    public let vocabSize: Int
    public let worldSize: Int

    public init(numLayers: Int, hiddenDim: Int, vocabSize: Int, worldSize: Int) {
        self.numLayers = numLayers
        self.hiddenDim = hiddenDim
        self.vocabSize = vocabSize
        self.worldSize = worldSize
    }
}

// MARK: - UncheckedSendableLLMModel
//
// Swift 6 wrapper that satisfies Sendable for model inits across actor boundaries.
// Safe because LLMModel implementations (LlamaModelTP, LlamaModel, etc.) are
// single-owner reference types that are constructed, then handed off exactly
// once to the actor that will own them. There is no concurrent access.

public struct UncheckedSendableLLMModel: @unchecked Sendable {
    public let value: any LLMModel
    public init(value: any LLMModel) { self.value = value }
}

// MARK: - StubTokenizer
//
// A minimal MLXLMCommon.Tokenizer implementation used when constructing TensorParallelEngine
// from ClusterDiscovery. The engine's `generate` API takes raw token IDs, so the
// tokenizer is only needed for chat-template formatting (PR 4d path). This stub
// satisfies the protocol requirement without pulling in the full swift-transformers
// stack at ClusterDiscovery construction time.

public struct StubTokenizer: MLXLMCommon.Tokenizer, Sendable {
    public init() {}
    public func encode(text: String, addSpecialTokens: Bool) -> [Int] { [] }
    public func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String { "" }
    public func convertTokenToId(_ token: String) -> Int? { nil }
    public func convertIdToToken(_ id: Int) -> String? { nil }
    public var bosToken: String? { nil }
    public var eosToken: String? { nil }
    public var unknownToken: String? { nil }
    public func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] { [] }
}

// MARK: - ClusterSessionSendable (protocol for testability)

/// Minimal send-only interface extracted from ClusterSession so tests can
/// inject a mock without needing a real ThunderboltLink connection.
///
/// `ClusterSession` conforms to this protocol. Tests use `MockClusterSession`.
public protocol ClusterSessionSendable: Sendable {
    /// Send a raw frame to rank 1. Throws on link failure.
    func sendInferenceFrame(_ data: Data) async throws
}

// MARK: - ClusterSession conformance

extension ClusterSession: ClusterSessionSendable {
    /// Send `data` as a sealed inference frame over the active ThunderboltLink
    /// connection. The frame is wrapped in AES-256-GCM using the session key
    /// established at handshake, so all post-handshake control + inference
    /// traffic (TP and PP) is encrypted on the wire. PP's inner sealing via
    /// TensorCrypto remains in place — it provides defense in depth and lets
    /// rank-1's PP server validate the inner ciphertext against tampering
    /// independently of the outer link layer.
    ///
    /// Throws `ClusterError.notReady` if the session isn't ready, or any
    /// underlying CryptoKit error if sealing fails.
    public func sendInferenceFrame(_ data: Data) async throws {
        let conn = try connection()
        let key = try sessionKey()
        let sealed = try ClusterLinkSeal.seal(data, key: key)
        try await conn.send(sealed)
    }
}

// MARK: - TensorParallelEngine (rank 0)

/// Drives tensor-parallel inference from rank 0's perspective.
///
/// Both ranks load `LlamaModelTP` and call `model.callAsFunction(input)` in
/// lockstep; the sharded linear layers internally allreduce activations via
/// the `DistributedGroup`. Both ranks produce identical logits; rank 0
/// samples the next token (greedy) and signals rank 1 to advance.
///
/// On a singleton group (worldSize=1), this degenerates to ordinary
/// single-rank inference — the sharded layers' allreduce is a no-op.
///
/// Greedy-only: no temperature, top_p, or top_k. Beam search and other
/// sampling strategies are out of scope for PR 4b.
public actor TensorParallelEngine {
    private let config: TensorParallelConfig
    /// Held as `any LLMModel` so the engine protocol-types correctly while
    /// remaining usable as a KVCacheDimensionProvider (via LlamaModelTP's
    /// `newCache(parameters:)` conformance).
    ///
    /// `nonisolated(unsafe)` because `LlamaModelTP` (and other LLMModel
    /// implementations) are reference types without explicit `Sendable` conformance.
    /// Safety: the model is constructed before the actor is created and is
    /// never mutated after init — only `callAsFunction` is called (read-only
    /// in practice for inference) and always from within actor isolation.
    nonisolated(unsafe) private let model: any LLMModel
    private let tokenizer: any MLXLMCommon.Tokenizer
    private var cache: [any KVCache]
    private let session: any ClusterSessionSendable

    private let logger = Logger(
        subsystem: "io.darkbloom.provider", category: "TensorParallelEngine")

    public init(
        config: TensorParallelConfig,
        model: UncheckedSendableLLMModel,
        tokenizer: any MLXLMCommon.Tokenizer,
        session: any ClusterSessionSendable
    ) {
        self.config = config
        self.model = model.value
        self.tokenizer = tokenizer
        self.session = session
        self.cache = []
        logger.info("TensorParallelEngine: layers=\(config.numLayers) hidden=\(config.hiddenDim) vocab=\(config.vocabSize) world=\(config.worldSize)")
    }

    /// Reset the KV cache to a fresh state. Called between distinct requests.
    public func resetCache() {
        cache = model.newCache(parameters: nil)
        logger.info("TP KV cache reset (\(self.cache.count) layer slots)")
    }

    // MARK: - Generate

    /// Generate up to `maxTokens` greedy tokens for the given prompt.
    ///
    /// Yields each sampled token ID to the returned `AsyncStream` as it's produced.
    /// The stream completes when:
    ///   - An EOS token ID in `eosTokenIDs` is sampled, OR
    ///   - `maxTokens` tokens have been generated, OR
    ///   - A fatal error occurs (stream finishes cleanly; error is logged).
    ///
    /// In all cases a `sessionStop` frame is sent to rank 1 before the stream ends.
    ///
    /// Rank 1 must be running `TensorParallelServer.serve()` concurrently. Both ranks
    /// call `model.callAsFunction` in lockstep; jaccl allreduces inside the sharded
    /// layers handle synchronization. Rank 1 discards its logits; only rank 0 samples.
    public func generate(
        promptTokens: [Int],
        maxTokens: Int,
        eosTokenIDs: Set<Int>
    ) -> AsyncStream<Int> {
        AsyncStream { continuation in
            let task = Task {
                // 1. Fresh request UID.
                let uid = UUID().uuidString

                // 2. Reset KV cache.
                self.cache = self.model.newCache(parameters: nil)

                // 3. Send promptTokens to rank 1.
                do {
                    let promptPayload = PromptTokensPayload(
                        uid: uid, tokens: promptTokens, maxTokens: maxTokens)
                    let frame = try ClusterFrame.encodeJSON(type: .promptTokens, value: promptPayload)
                    try await self.session.sendInferenceFrame(frame)
                } catch {
                    self.logger.error("Failed to send promptTokens: \(error)")
                    continuation.finish()
                    return
                }

                // 4. Prefill: both ranks run forward pass over the prompt in lockstep.
                //    jaccl allreduce inside LlamaModelTP handles the sync.
                let prefillInput = MLXArray(promptTokens.map { Int32($0) }, [1, promptTokens.count])
                var logits = self.model.callAsFunction(prefillInput, cache: self.cache)
                eval(logits)

                // 5. Sample greedy token from the last position.
                var nextToken = self.greedySample(logits: logits)

                // 6. Send first token back to rank 1.
                do {
                    let stepPayload = StepTokenPayload(uid: uid, token: nextToken)
                    let stepFrame = try ClusterFrame.encodeJSON(type: .stepToken, value: stepPayload)
                    try await self.session.sendInferenceFrame(stepFrame)
                } catch {
                    self.logger.error("Failed to send initial stepToken: \(error)")
                    // Still try to send sessionStop so rank 1 doesn't hang.
                    try? await self.sendStop(uid: uid)
                    continuation.finish()
                    return
                }

                // Yield the prefill's sampled token.
                continuation.yield(nextToken)

                if eosTokenIDs.contains(nextToken) || maxTokens <= 1 {
                    try? await self.sendStop(uid: uid)
                    continuation.finish()
                    return
                }

                // 7. Decode loop.
                var generated = 1
                var fatalError = false

                while generated < maxTokens && !eosTokenIDs.contains(nextToken) {
                    // Both ranks call model.callAsFunction with the previously
                    // sampled token. The allreduce inside sharded layers syncs them.
                    let decodeInput = MLXArray([Int32(nextToken)], [1, 1])
                    logits = self.model.callAsFunction(decodeInput, cache: self.cache)
                    eval(logits)

                    nextToken = self.greedySample(logits: logits)
                    generated += 1

                    // Send the token to rank 1 so it can advance its cache.
                    do {
                        let stepPayload = StepTokenPayload(uid: uid, token: nextToken)
                        let stepFrame = try ClusterFrame.encodeJSON(type: .stepToken, value: stepPayload)
                        try await self.session.sendInferenceFrame(stepFrame)
                    } catch {
                        self.logger.error("Decode loop: sendInferenceFrame failed: \(error)")
                        fatalError = true
                        break
                    }

                    continuation.yield(nextToken)
                }

                // 8. End of generation — send sessionStop.
                try? await self.sendStop(uid: uid)
                if fatalError {
                    self.logger.warning(
                        "TensorParallelEngine.generate ended with a link error after \(generated) tokens")
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    // MARK: - Helpers

    /// Extract the argmax token from the logits at the last sequence position.
    /// Input shape: [1, seqLen, vocabSize] or [seqLen, vocabSize].
    private func greedySample(logits: MLXArray) -> Int {
        // Take the last token's logits regardless of batch/seq layout.
        let lastLogits = logits[.ellipsis, -1, 0...]
        let tokenArr = lastLogits.argMax(axis: -1)
        eval(tokenArr)
        return Int(tokenArr.item(Int32.self))
    }

    private func sendStop(uid: String) async throws {
        let payload = SessionStopPayload(uid: uid)
        let frame = try ClusterFrame.encodeJSON(type: .sessionStop, value: payload)
        try await session.sendInferenceFrame(frame)
    }
}

// MARK: - TensorParallelServer (rank 1)

/// Drives the rank-1 side of tensor-parallel inference.
///
/// Rank 1 calls `model.callAsFunction` in lockstep with rank 0 — both ranks
/// run all N layers simultaneously, with jaccl allreduces handling per-layer
/// synchronization. Rank 1 discards its logits entirely; only rank 0 samples
/// the next token and sends it back as a `stepToken` frame.
///
/// The serve loop is driven by frames received via `ClusterPeer.inferenceHandler`.
/// Use `makeInferenceHandler()` to get the callback to pass into
/// `ClusterPeer.serve(inferenceHandler:bootstrapHandler:)`.
///
/// Lifetime: the serve loop runs until a `sessionStop` frame is received OR the
/// peer disconnects. Jaccl allreduces will block indefinitely if rank 0 disconnects
/// mid-decode; that failure mode is handled in PR 4d.
public actor TensorParallelServer {
    private let config: TensorParallelConfig
    /// See `TensorParallelEngine.model` — same `nonisolated(unsafe)` rationale.
    nonisolated(unsafe) private let model: any LLMModel
    private var cache: [any KVCache]

    private let logger = Logger(
        subsystem: "io.darkbloom.provider", category: "TensorParallelServer")

    public init(
        config: TensorParallelConfig,
        model: UncheckedSendableLLMModel
    ) {
        self.config = config
        self.model = model.value
        self.cache = []
        logger.info(
            "TensorParallelServer initialized: layers=\(config.numLayers), worldSize=\(config.worldSize)")
    }

    // MARK: - Frame dispatch (actor-isolated)

    /// Process one incoming TP inference frame from rank 0.
    ///
    /// Called by `ClusterDiscovery`'s `inferenceHandler` closure, which extracts
    /// the raw frame from the ThunderboltLink receive loop and routes it here.
    /// Rank 1 never sends back in the TP protocol, so the connection and session
    /// key are not needed at this level.
    ///
    /// Handles:
    ///   - `.promptTokens` → reset cache, run prefill (discard logits)
    ///   - `.stepToken`    → run decode step with the given token (discard logits)
    ///   - `.sessionStop`  → log completion, clear cache
    public func handleFrame(_ frame: Data) async throws {
        let msgType: ClusterMsgType
        do {
            msgType = try ClusterFrame.decodeType(from: frame)
        } catch {
            logger.warning("Failed to decode frame type: \(error)")
            return
        }

        switch msgType {
        case .promptTokens:
            let payload: PromptTokensPayload
            do {
                payload = try ClusterFrame.decodeJSON(PromptTokensPayload.self, from: frame)
            } catch {
                logger.warning("Failed to decode promptTokens payload: \(error)")
                return
            }
            // Reset KV cache for the new request.
            cache = model.newCache(parameters: nil)
            logger.info("TP rank 1: prefill uid=\(payload.uid), \(payload.tokens.count) tokens")

            // Run prefill — syncs with rank 0's matching callAsFunction via allreduce.
            // CRITICAL: rank 1 MUST `eval()` the result. MLX is lazy — without eval
            // the computation graph (including the per-layer allreduce nodes) is
            // built but never executed. Rank 0 evals its result and triggers its
            // allreduce, which would block forever waiting for rank 1 to participate.
            let prefillInput = MLXArray(payload.tokens.map { Int32($0) }, [1, payload.tokens.count])
            let prefillLogits = model.callAsFunction(prefillInput, cache: cache)
            eval(prefillLogits)
            // Rank 1 discards the evaluated logits. Rank 0 samples the first
            // token and sends it back as a stepToken frame.

        case .stepToken:
            let payload: StepTokenPayload
            do {
                payload = try ClusterFrame.decodeJSON(StepTokenPayload.self, from: frame)
            } catch {
                logger.warning("Failed to decode stepToken payload: \(error)")
                return
            }
            // Run decode step with rank 0's sampled token — syncs via allreduce.
            // See the .promptTokens case above for why eval() is required.
            let decodeInput = MLXArray([Int32(payload.token)], [1, 1])
            let decodeLogits = model.callAsFunction(decodeInput, cache: cache)
            eval(decodeLogits)
            // Rank 1 discards the evaluated logits; rank 0 continues sampling.

        case .sessionStop:
            // Generation complete for this request. Reset cache so the server
            // is ready for the next request immediately.
            let payload = try? ClusterFrame.decodeJSON(SessionStopPayload.self, from: frame)
            logger.info("TP rank 1: sessionStop uid=\(payload?.uid ?? "<unknown>")")
            cache = []

        default:
            logger.warning("TensorParallelServer: unexpected frame type \(msgType.rawValue), ignoring")
        }
    }

    /// Reset the KV cache to a fresh state. Called between distinct requests.
    public func resetCache() {
        cache = model.newCache(parameters: nil)
        logger.info("TP server KV cache reset")
    }
}
