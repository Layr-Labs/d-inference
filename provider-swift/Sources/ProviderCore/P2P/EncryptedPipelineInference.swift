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

// MARK: - EncryptedPipelineEngine (rank 0)

/// Drives encrypted pipeline-parallel inference from rank 0's perspective.
///
/// Rank 0 runs embedding + the first `splitLayer` transformer blocks, then seals
/// the activation with AES-256-GCM and sends it to rank 1 over ThunderboltLink.
/// Rank 1 completes the forward pass, samples a token, seals the token ID, and
/// sends it back. This repeats for each decode step.
///
/// On link failure, each step is retried up to 3 times with a 3-second delay.
/// After 3 consecutive failures, `ClusterError.serviceUnavailable` is thrown —
/// callers should map this to HTTP 429.
public actor EncryptedPipelineEngine {
    private let config: EncryptedPipelineConfig
    private let model: LlamaModel
    private let tokenizer: any Tokenizer
    private var cache: [any KVCache]
    private let session: ClusterSession

    private let logger = Logger(subsystem: "io.darkbloom.provider", category: "EncryptedPipelineEngine")

    public init(
        config: EncryptedPipelineConfig,
        model: LlamaModel,
        tokenizer: any Tokenizer,
        session: ClusterSession
    ) {
        self.config = config
        self.model = model
        self.tokenizer = tokenizer
        self.session = session
        self.cache = model.newCache(parameters: nil)
            .prefix(config.splitLayer)
            .map { $0 }
    }

    /// Stream tokens for a chat request.
    /// Rank 1 must be running `EncryptedPipelineServer.serve()` concurrently.
    public func generate(
        messages: [[String: any Sendable]],
        maxTokens: Int = 512,
        eosToken: Int = 2
    ) -> AsyncThrowingStream<GenerationEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let promptTokens = try self.tokenizer.applyChatTemplate(
                        messages: messages, tools: nil, additionalContext: nil)

                    await self.session.setInferenceInFlight(true)

                    var generated = 0
                    let t0 = Date()

                    var lastToken = try await self.step(
                        tokens: promptTokens, isPrefill: true, seqLen: promptTokens.count)
                    generated += 1

                    while generated < maxTokens && lastToken != eosToken {
                        if let text = Optional(self.tokenizer.decode(tokenIds: [lastToken])),
                           !text.isEmpty
                        {
                            continuation.yield(.chunk(text))
                        }
                        lastToken = try await self.step(
                            tokens: [lastToken], isPrefill: false, seqLen: 1)
                        generated += 1
                    }

                    try await self.sendStop()

                    await self.session.setInferenceInFlight(false)

                    let elapsed = Date().timeIntervalSince(t0)
                    let tps = elapsed > 0 ? Double(generated) / elapsed : 0
                    continuation.yield(.info(
                        promptTokens: promptTokens.count,
                        completionTokens: generated,
                        tokensPerSecond: tps))
                    continuation.finish()
                } catch {
                    await self.session.setInferenceInFlight(false)
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
                Task { await self.session.setInferenceInFlight(false) }
            }
        }
    }

    // MARK: - Retry wrapper

    private func step(tokens: [Int], isPrefill: Bool, seqLen: Int) async throws -> Int {
        for attempt in 0 ..< 3 {
            do {
                return try await attemptStep(tokens: tokens, isPrefill: isPrefill, seqLen: seqLen)
            } catch {
                logger.warning("Step attempt \(attempt + 1)/3 failed: \(error). Retrying in 3s.")
                if attempt < 2 {
                    try? await Task.sleep(for: .seconds(3))
                }
            }
        }
        throw ClusterError.serviceUnavailable
    }

    // MARK: - Single attempt

    private func attemptStep(tokens: [Int], isPrefill: Bool, seqLen: Int) async throws -> Int {
        let conn = try await session.connection()
        let key = try await session.sessionKey()

        // Run rank 0's layers.
        let inputArr = MLXArray(tokens.map { Int32($0) }, [1, tokens.count])
        let activation = model.callPartial(
            inputArr,
            layerRange: config.rank0Range,
            applyEmbedding: true,
            applyNorm: false,
            applyHead: false,
            cache: isPrefill ? nil : cache)
        eval(activation)

        // Seal and send activation.
        let sealedActivation = try TensorCrypto.sealActivation(
            seqLen: Int32(seqLen), activation: activation, key: key)
        let stepFrame = ClusterFrame.encode(type: .inferenceStep, payload: sealedActivation)
        try await conn.send(stepFrame)

        // Receive sealed token.
        let tokenFrame = try await conn.receive()
        let tokenType = try ClusterFrame.decodeType(from: tokenFrame)
        guard tokenType == .inferenceToken else {
            throw ClusterError.unexpectedMessage(expected: .inferenceToken, got: tokenType)
        }
        let tokenPayload = ClusterFrame.decodePayload(from: tokenFrame)
        return Int(try TensorCrypto.openToken(tokenPayload, key: key))
    }

    private func sendStop() async throws {
        let conn = try await session.connection()
        let key = try await session.sessionKey()
        let sealedStop = try TensorCrypto.sealStop(key: key)
        let stopFrame = ClusterFrame.encode(type: .inferenceStep, payload: sealedStop)
        try await conn.send(stopFrame)
    }
}

// MARK: - EncryptedPipelineServer (rank 1)

/// Rank 1's inference server. Paired with `ClusterPeer.serve(inferenceHandler:)`.
///
/// For each request: receives AES-GCM sealed activations from rank 0, runs the
/// remaining transformer blocks + lm_head, seals the sampled token, and sends it
/// back. Loops until a stop sentinel (seqLen == -1) is received.
public final class EncryptedPipelineServer: @unchecked Sendable {
    private let config: EncryptedPipelineConfig
    private let model: LlamaModel
    private var cache: [any KVCache]

    private let logger = Logger(subsystem: "io.darkbloom.provider", category: "EncryptedPipelineServer")

    public init(config: EncryptedPipelineConfig, model: LlamaModel) {
        self.config = config
        self.model = model
        self.cache = model.newCache(parameters: nil)
            .suffix(config.numLayers - config.splitLayer)
            .map { $0 }
    }

    /// Returns a handler compatible with `ClusterPeer.serve(modelState:inferenceHandler:)`.
    /// The handler receives the triggering frame so the payload isn't lost.
    public func makeInferenceHandler()
        -> @Sendable (ThunderboltConnection, SymmetricKey, Data) async throws -> Void
    {
        return { [self] conn, key, firstFrame in
            try await self.handleRequest(conn: conn, key: key, firstFrame: firstFrame)
        }
    }

    private func handleRequest(
        conn: ThunderboltConnection,
        key: SymmetricKey,
        firstFrame: Data
    ) async throws {
        var frame = firstFrame
        var isPrefill = true

        while true {
            let payload = ClusterFrame.decodePayload(from: frame)
            let (seqLen, activation) = try TensorCrypto.openActivation(
                payload, key: key, hiddenDim: config.hiddenDim)

            if seqLen == -1 { return }

            guard let act = activation else { return }

            // Run rank 1's layers.
            let logits = model.callPartial(
                act,
                layerRange: config.rank1Range,
                applyEmbedding: false,
                applyNorm: true,
                applyHead: true,
                cache: isPrefill ? nil : cache)

            let lastLogits = logits[0..., -1, 0...]
            let tokenArr = lastLogits.argMax(axis: -1)
            eval(tokenArr)
            isPrefill = false

            let tokenID = Int32(tokenArr.item(Int32.self))
            let sealedToken = try TensorCrypto.sealToken(tokenID, key: key)
            let tokenFrame = ClusterFrame.encode(type: .inferenceToken, payload: sealedToken)
            try await conn.send(tokenFrame)

            // Wait for next step from rank 0.
            let nextFrame = try await conn.receive()
            let nextType = try ClusterFrame.decodeType(from: nextFrame)
            guard nextType == .inferenceStep else {
                logger.warning("Expected inferenceStep, got \(nextType.rawValue). Ending request.")
                return
            }
            frame = nextFrame
        }
    }
}
