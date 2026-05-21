import CryptoKit
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
#if canImport(os)
import os
#endif

// MARK: - EncryptedPipelineConfig

/// Describes how to split a model across two machines for encrypted pipeline inference.
/// Unlike PipelineConfig, this uses ThunderboltLink + AES-256-GCM for tensor transfer
/// rather than jaccl send/recv, giving us SE-authenticated confidentiality in transit.
public struct EncryptedPipelineConfig: Sendable {
    public let splitLayer: Int
    public let numLayers: Int
    public let hiddenDim: Int
    public let vocabSize: Int

    public init(splitLayer: Int, numLayers: Int, hiddenDim: Int, vocabSize: Int) {
        self.splitLayer = splitLayer
        self.numLayers = numLayers
        self.hiddenDim = hiddenDim
        self.vocabSize = vocabSize
    }

    var rank0Range: Range<Int> { 0 ..< splitLayer }
    var rank1Range: Range<Int> { splitLayer ..< numLayers }
}

// MARK: - PPClusterSession (protocol for testability)

/// Bidirectional session interface for pipeline-parallel inference.
///
/// Extends `ClusterSessionSendable` (which provides `sendInferenceFrame`) with
/// receive and key access, because PP rank 0 must both send `ppActivation` frames
/// and receive `ppToken` responses in an alternating exchange.
///
/// `ClusterSession` conforms to this protocol. Tests use `MockPPSession`.
public protocol PPClusterSession: ClusterSessionSendable {
    /// Receive the next raw inference frame from rank 1. Throws on link failure.
    func receiveInferenceFrame() async throws -> Data
    /// Return the current session key for AES-GCM operations. Throws if not ready.
    func currentSessionKey() async throws -> SymmetricKey
}

// MARK: - ClusterSession conformance to PPClusterSession
//
// ClusterSession already conforms to ClusterSessionSendable (via the extension in
// TensorParallelInference.swift, which provides sendInferenceFrame). Here we add
// the two PP-specific methods to complete the PPClusterSession conformance.

extension ClusterSession: PPClusterSession {
    /// Receive the next raw frame from rank 1. Throws `ClusterError.notReady` if not ready.
    public func receiveInferenceFrame() async throws -> Data {
        let conn = try connection()
        return try await conn.receive()
    }

    /// Return the current AES-256-GCM session key. Throws if the session isn't ready.
    public func currentSessionKey() async throws -> SymmetricKey {
        return try sessionKey()
    }
}

// MARK: - EncryptedPipelineEngine (rank 0)

/// Drives encrypted pipeline-parallel inference from rank 0's perspective.
///
/// Rank 0 runs embedding + the first `splitLayer` transformer blocks, then seals
/// the activation with AES-256-GCM and sends it to rank 1 as a `ppActivation` frame.
/// Rank 1 completes the forward pass (layers splitLayer..N + norm + lm_head), samples
/// a token (greedy argmax), seals the token ID, and returns it as a `ppToken` frame.
/// This alternating exchange repeats for each decode step.
///
/// Frame protocol (rank 0 → rank 1 per request):
///   ppActivation { uid, seqLen, sealedActivation }  — one per step (prefill or decode)
///   ppSessionEnd { uid }                              — EOS reached / maxTokens exhausted
///
/// Frame protocol (rank 1 → rank 0):
///   ppToken { uid, sealedToken }                     — one per step, after sampling
///
/// KV cache: rank 0 holds cache slots for layers 0..splitLayer only. The cache array
/// is sliced from the full `model.newCache(parameters:nil)` at init time.
///
/// On link failure, each step is retried up to 3 times with a 3-second delay.
/// After 3 consecutive failures, `ClusterError.serviceUnavailable` is thrown.
public actor EncryptedPipelineEngine {
    private let config: EncryptedPipelineConfig
    /// `nonisolated(unsafe)`: LlamaModel is a reference type without Sendable conformance.
    /// Safety: constructed before the actor is created, owned exclusively by this actor
    /// from init forward, and only called from within actor isolation.
    nonisolated(unsafe) private let model: LlamaModel
    private var cache: [any KVCache]
    private let session: any PPClusterSession

    private let logger = Logger(subsystem: "io.darkbloom.provider", category: "EncryptedPipelineEngine")

    public init(
        config: EncryptedPipelineConfig,
        model: LlamaModel,
        session: any PPClusterSession
    ) {
        self.config = config
        self.model = model
        self.session = session
        // Slice the cache to rank 0's layers only (0 ..< splitLayer).
        // model.newCache creates entries for all N layers; we keep only the first splitLayer.
        self.cache = model.newCache(parameters: nil)
            .prefix(config.splitLayer)
            .map { $0 }
        logger.info(
            "EncryptedPipelineEngine: splitLayer=\(config.splitLayer) numLayers=\(config.numLayers) hidden=\(config.hiddenDim) vocab=\(config.vocabSize)")
    }

    /// Reset the KV cache to a fresh state. Called between distinct requests.
    public func resetCache() {
        cache = model.newCache(parameters: nil)
            .prefix(config.splitLayer)
            .map { $0 }
        logger.info("PP engine KV cache reset (\(self.cache.count) rank-0 layer slots)")
    }

    // MARK: - Generate

    /// Generate up to `maxTokens` greedy tokens for the given prompt token IDs.
    ///
    /// Yields each sampled token ID (as returned from rank 1) to the returned
    /// `AsyncStream<Int>`. The stream completes when:
    ///   - A token ID in `eosTokenIDs` is received from rank 1, OR
    ///   - `maxTokens` tokens have been generated, OR
    ///   - A fatal error occurs (stream finishes cleanly; error is logged).
    ///
    /// In all cases a `ppSessionEnd` frame is sent to rank 1 before the stream ends.
    /// Rank 1 must be running `EncryptedPipelineServer.serve()` concurrently.
    public func generate(
        promptTokens: [Int],
        maxTokens: Int,
        eosTokenIDs: Set<Int>
    ) -> AsyncStream<Int> {
        AsyncStream { continuation in
            let task = Task {
                // Fresh request UID.
                let uid = UUID().uuidString

                // Reset KV cache for this request.
                self.cache = self.model.newCache(parameters: nil)
                    .prefix(self.config.splitLayer)
                    .map { $0 }

                // 1. Prefill: run layers 0..splitLayer over all prompt tokens.
                let prefillInput = MLXArray(promptTokens.map { Int32($0) }, [1, promptTokens.count])
                let prefillActivation = self.model.callPartial(
                    prefillInput,
                    layerRange: self.config.rank0Range,
                    applyEmbedding: true,
                    applyNorm: false,
                    applyHead: false,
                    cache: self.cache)
                eval(prefillActivation)

                // 2. Seal and send prefill activation to rank 1.
                let firstToken: Int
                do {
                    firstToken = try await self.sendActivationAndReceiveToken(
                        uid: uid,
                        seqLen: promptTokens.count,
                        activation: prefillActivation)
                } catch {
                    self.logger.error("PP prefill exchange failed: \(error)")
                    try? await self.sendSessionEnd(uid: uid)
                    continuation.finish()
                    return
                }

                // Yield first token, check EOS.
                continuation.yield(firstToken)
                if eosTokenIDs.contains(firstToken) || maxTokens <= 1 {
                    try? await self.sendSessionEnd(uid: uid)
                    continuation.finish()
                    return
                }

                // 3. Decode loop.
                var lastToken = firstToken
                var generated = 1
                var fatalError = false

                while generated < maxTokens && !eosTokenIDs.contains(lastToken) {
                    // Forward [lastToken] through rank 0's layers.
                    let decodeInput = MLXArray([Int32(lastToken)], [1, 1])
                    let decodeActivation = self.model.callPartial(
                        decodeInput,
                        layerRange: self.config.rank0Range,
                        applyEmbedding: true,
                        applyNorm: false,
                        applyHead: false,
                        cache: self.cache)
                    eval(decodeActivation)

                    let nextToken: Int
                    do {
                        nextToken = try await self.sendActivationAndReceiveToken(
                            uid: uid,
                            seqLen: 1,
                            activation: decodeActivation)
                    } catch {
                        self.logger.error("PP decode step \(generated) failed: \(error)")
                        fatalError = true
                        break
                    }

                    lastToken = nextToken
                    generated += 1
                    continuation.yield(nextToken)
                }

                // 4. Signal end of request.
                try? await self.sendSessionEnd(uid: uid)
                if fatalError {
                    self.logger.warning(
                        "EncryptedPipelineEngine.generate ended with a link error after \(generated) tokens")
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }

    // MARK: - Step helpers

    /// Seal the activation, send a `ppActivation` frame to rank 1, then wait for
    /// and decrypt the `ppToken` response. Retries up to 3 times on failure.
    private func sendActivationAndReceiveToken(
        uid: String,
        seqLen: Int,
        activation: MLXArray
    ) async throws -> Int {
        for attempt in 0 ..< 3 {
            do {
                return try await attemptActivationExchange(
                    uid: uid, seqLen: seqLen, activation: activation)
            } catch {
                logger.warning("PP step attempt \(attempt + 1)/3 failed: \(error). Retrying in 3s.")
                if attempt < 2 {
                    try? await Task.sleep(for: .seconds(3))
                }
            }
        }
        throw ClusterError.serviceUnavailable
    }

    private func attemptActivationExchange(
        uid: String,
        seqLen: Int,
        activation: MLXArray
    ) async throws -> Int {
        let key = try await session.currentSessionKey()

        // Seal activation with TensorCrypto (inner AES-GCM layer).
        let sealedActivation = try TensorCrypto.sealActivation(
            seqLen: Int32(seqLen), activation: activation, key: key)

        // Build ppActivation JSON frame.
        let activationPayload = PPActivationPayload(
            uid: uid, seqLen: seqLen, sealedActivation: sealedActivation)
        let activationFrame = try ClusterFrame.encodeJSON(type: .ppActivation, value: activationPayload)
        try await session.sendInferenceFrame(activationFrame)

        // Wait for ppToken response.
        let tokenFrame = try await session.receiveInferenceFrame()
        let tokenType = try ClusterFrame.decodeType(from: tokenFrame)
        guard tokenType == .ppToken else {
            throw ClusterError.unexpectedMessage(expected: .ppToken, got: tokenType)
        }
        let tokenPayload = try ClusterFrame.decodeJSON(PPTokenPayload.self, from: tokenFrame)
        let tokenID = Int(try TensorCrypto.openToken(tokenPayload.sealedToken, key: key))
        return tokenID
    }

    private func sendSessionEnd(uid: String) async throws {
        let payload = PPSessionEndPayload(uid: uid)
        let frame = try ClusterFrame.encodeJSON(type: .ppSessionEnd, value: payload)
        try await session.sendInferenceFrame(frame)
    }
}

// MARK: - EncryptedPipelineServer (rank 1)

/// Rank 1's inference server for pipeline-parallel decode.
///
/// Receives `ppActivation` frames from rank 0, runs layers splitLayer..N +
/// final RMS norm + lm_head, samples the next token (greedy argmax), seals
/// the token ID, and sends it back as a `ppToken` frame. Loops until a
/// `ppSessionEnd` frame is received.
///
/// KV cache: rank 1 holds cache slots for layers splitLayer..numLayers only.
/// The cache array is sliced from `model.newCache(parameters:nil)` at init.
///
/// Integration: call `makeInferenceHandler()` to obtain the callback for
/// `ClusterPeer.serve(modelState:inferenceHandler:bootstrapHandler:)`.
public final class EncryptedPipelineServer: @unchecked Sendable {
    private let config: EncryptedPipelineConfig
    private let model: LlamaModel
    private var cache: [any KVCache]

    private let logger = Logger(subsystem: "io.darkbloom.provider", category: "EncryptedPipelineServer")

    public init(config: EncryptedPipelineConfig, model: LlamaModel) {
        self.config = config
        self.model = model
        // Slice the cache to rank 1's layers only (splitLayer ..< numLayers).
        self.cache = model.newCache(parameters: nil)
            .suffix(config.numLayers - config.splitLayer)
            .map { $0 }
        logger.info(
            "EncryptedPipelineServer: splitLayer=\(config.splitLayer) numLayers=\(config.numLayers) hidden=\(config.hiddenDim)")
    }

    /// Returns a handler compatible with `ClusterPeer.serve(modelState:inferenceHandler:)`.
    ///
    /// The handler is called by `ClusterPeer` for each incoming inference frame (including
    /// `ppActivation` and `ppSessionEnd`). It maintains a per-request decode loop,
    /// sending `ppToken` frames back to rank 0 after each sampling step.
    ///
    /// TP frames (`promptTokens`, `stepToken`, `sessionStop`) that arrive here are
    /// silently ignored — they belong to a different engine and won't appear in
    /// normal operation when the dispatcher selects PP.
    public func makeInferenceHandler()
        -> @Sendable (ThunderboltConnection, SymmetricKey, Data) async throws -> Void
    {
        return { [self] conn, key, firstFrame in
            try await self.handleRequest(conn: conn, key: key, firstFrame: firstFrame)
        }
    }

    // MARK: - Request loop

    private func handleRequest(
        conn: ThunderboltConnection,
        key: SymmetricKey,
        firstFrame: Data
    ) async throws {
        var frame = firstFrame

        while true {
            let msgType: ClusterMsgType
            do {
                msgType = try ClusterFrame.decodeType(from: frame)
            } catch {
                logger.warning("PP server: failed to decode frame type: \(error)")
                return
            }

            switch msgType {
            case .ppActivation:
                let payload: PPActivationPayload
                do {
                    payload = try ClusterFrame.decodeJSON(PPActivationPayload.self, from: frame)
                } catch {
                    logger.warning("PP server: failed to decode ppActivation payload: \(error)")
                    return
                }

                // Decrypt activation (inner AES-GCM layer via TensorCrypto).
                let (_, activation) = try TensorCrypto.openActivation(
                    payload.sealedActivation, key: key, hiddenDim: config.hiddenDim)

                guard let act = activation else {
                    // seqLen == -1 is the legacy stop sentinel — treat as session end.
                    logger.info("PP server: received stop sentinel (seqLen=-1), ending request")
                    cache = model.newCache(parameters: nil)
                        .suffix(config.numLayers - config.splitLayer)
                        .map { $0 }
                    return
                }

                // Run layers splitLayer..numLayers + norm + lm_head → logits.
                let logits = model.callPartial(
                    act,
                    layerRange: config.rank1Range,
                    applyEmbedding: false,
                    applyNorm: true,
                    applyHead: true,
                    cache: cache)
                eval(logits)

                // Greedy sample: argmax over the last token's logits.
                // logits shape: [1, seqLen, vocabSize]
                let lastLogits = logits[0..., -1, 0...]
                let tokenArr = lastLogits.argMax(axis: -1)
                eval(tokenArr)
                let tokenID = Int32(tokenArr.item(Int32.self))

                // Seal token and send ppToken back to rank 0.
                let sealedToken = try TensorCrypto.sealToken(tokenID, key: key)
                let tokenResponse = PPTokenPayload(uid: payload.uid, sealedToken: sealedToken)
                let tokenFrame = try ClusterFrame.encodeJSON(type: .ppToken, value: tokenResponse)
                try await conn.send(tokenFrame)

            case .ppSessionEnd:
                let payload = try? ClusterFrame.decodeJSON(PPSessionEndPayload.self, from: frame)
                logger.info("PP server: ppSessionEnd uid=\(payload?.uid ?? "<unknown>"), resetting cache")
                // Reset cache for the next request.
                cache = model.newCache(parameters: nil)
                    .suffix(config.numLayers - config.splitLayer)
                    .map { $0 }
                return

            default:
                // TP frames or unknown — log and wait for next frame.
                logger.warning(
                    "PP server: unexpected frame type \(msgType.rawValue) — not a PP frame, ignoring")
            }

            // Receive next frame from rank 0.
            let nextFrame: Data
            do {
                nextFrame = try await conn.receive()
            } catch {
                logger.warning("PP server: receive failed: \(error)")
                return
            }
            frame = nextFrame
        }
    }

    /// Reset the KV cache to a fresh state. Called between distinct requests.
    public func resetCache() {
        cache = model.newCache(parameters: nil)
            .suffix(config.numLayers - config.splitLayer)
            .map { $0 }
        logger.info("PP server KV cache reset")
    }
}
