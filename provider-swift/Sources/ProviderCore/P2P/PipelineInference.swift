import Foundation
import MLX
import MLXLLM
import MLXLMCommon

// MARK: - PipelineConfig

/// Describes how to split a model across two machines for pipeline-parallel inference.
public struct PipelineConfig: Sendable {
    /// Which layer index begins rank 1's shard (exclusive upper bound for rank 0).
    public let splitLayer: Int
    /// Total transformer blocks in the model (e.g. 80 for Llama-3-70B).
    public let numLayers: Int
    /// Hidden dimension (e.g. 8192 for Llama-3-70B). Used for buffer sizing.
    public let hiddenDim: Int
    /// Vocabulary size for logit projection on rank 1.
    public let vocabSize: Int
    /// The distributed group (must already be initialized via DistributedGroup.initialize()).
    public let group: DistributedGroup

    public init(
        splitLayer: Int,
        numLayers: Int,
        hiddenDim: Int,
        vocabSize: Int,
        group: DistributedGroup
    ) {
        self.splitLayer = splitLayer
        self.numLayers = numLayers
        self.hiddenDim = hiddenDim
        self.vocabSize = vocabSize
        self.group = group
    }

    var rank0Range: Range<Int> { 0 ..< splitLayer }
    var rank1Range: Range<Int> { splitLayer ..< numLayers }
}

// MARK: - PipelineInferenceEngine (rank 0)

/// Drives single-request pipeline-parallel inference from rank 0's perspective.
///
/// Rank 0 runs the embedding + first half of transformer blocks, then sends
/// the activation tensor to rank 1 via RDMA. Rank 1 runs the remaining blocks,
/// samples a token, and sends the token ID back. This repeats per decode step.
///
/// Supports Llama-family models only (uses `LlamaModel.callPartial`).
public actor PipelineInferenceEngine {
    private let config: PipelineConfig
    private let model: LlamaModel
    private let tokenizer: any Tokenizer
    private var cache: [any KVCache]

    public init(config: PipelineConfig, model: LlamaModel, tokenizer: any Tokenizer) {
        self.config = config
        self.model = model
        self.tokenizer = tokenizer
        // KV cache for rank 0's layer range only.
        self.cache = model.newCache(parameters: nil)
            .prefix(config.splitLayer)
            .map { $0 }
    }

    /// Generate tokens for a chat completion request.
    /// Rank 1 must be running `PipelineServer.serveForever()` concurrently.
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

                    var generated = 0
                    var allTokens = promptTokens
                    let t0 = Date()

                    // Prefill: process entire prompt on rank 0, send activation to rank 1.
                    var lastToken = try await self.step(
                        tokens: promptTokens, isPrefill: true, seqLen: promptTokens.count)
                    generated += 1

                    // Decode loop.
                    while generated < maxTokens && lastToken != eosToken {
                        allTokens.append(lastToken)
                        lastToken = try await self.step(
                            tokens: [lastToken], isPrefill: false, seqLen: 1)
                        generated += 1

                        if let text = Optional(self.tokenizer.decode(tokenIds: [lastToken])), !text.isEmpty {
                            continuation.yield(.chunk(text))
                        }
                    }

                    // Signal rank 1 to stop serving this request.
                    try self.sendStopSignal()

                    let elapsed = Date().timeIntervalSince(t0)
                    let tps = elapsed > 0 ? Double(generated) / elapsed : 0
                    continuation.yield(.info(
                        promptTokens: promptTokens.count,
                        completionTokens: generated,
                        tokensPerSecond: tps))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    // MARK: - Private

    private func step(tokens: [Int], isPrefill: Bool, seqLen: Int) async throws -> Int {
        let group = config.group

        // 1. Send seqLen as a 1-element int32 so rank 1 knows what to expect.
        let seqLenArr = MLXArray(Int32(seqLen))
        let sentLen = seqLenArr.distributedSend(to: 1, group: group)
        eval(sentLen)

        // 2. Run rank 0's forward shard.
        let inputArr = MLXArray(tokens.map { Int32($0) }, [1, tokens.count])
        let activation = model.callPartial(
            inputArr,
            layerRange: config.rank0Range,
            applyEmbedding: true,
            applyNorm: false,
            applyHead: false,
            cache: isPrefill ? nil : cache)

        // 3. Send activation to rank 1.
        let sentActivation = activation.distributedSend(to: 1, group: group)
        eval(sentActivation)

        // 4. Receive token from rank 1.
        let tokenTemplate = MLXArray(Int32(0))
        let tokenArr = tokenTemplate.distributedRecvLike(from: 1, group: group)
        eval(tokenArr)

        return Int(tokenArr.item(Int32.self))
    }

    private func sendStopSignal() throws {
        // seqLen = -1 is the sentinel for "stop serving".
        let stop = MLXArray(Int32(-1))
        let sent = stop.distributedSend(to: 1, group: config.group)
        eval(sent)
    }
}

// MARK: - PipelineServer (rank 1)

/// Rank 1's server loop. Receives activations from rank 0, runs the remaining
/// transformer blocks, and sends token IDs back. Loops until a stop sentinel.
///
/// Supports Llama-family models only.
public final class PipelineServer: @unchecked Sendable {
    private let config: PipelineConfig
    private let model: LlamaModel
    private let cache: [any KVCache]

    public init(config: PipelineConfig, model: LlamaModel) {
        self.config = config
        self.model = model
        // KV cache for rank 1's layer range only, indexed from 0.
        self.cache = model.newCache(parameters: nil)
            .suffix(config.numLayers - config.splitLayer)
            .map { $0 }
    }

    /// Block indefinitely, serving activation tensors from rank 0.
    /// Returns when the stop sentinel (seqLen = -1) is received.
    public func serveForever() {
        let group = config.group
        let seqLenTemplate = MLXArray(Int32(0))
        var isPrefill = true

        while true {
            // 1. Receive seqLen from rank 0.
            let seqLenArr = seqLenTemplate.distributedRecvLike(from: 0, group: group)
            eval(seqLenArr)
            let seqLen = Int(seqLenArr.item(Int32.self))

            if seqLen == -1 { break }  // stop sentinel

            // 2. Receive activation tensor [1, seqLen, hiddenDim].
            let activationShape = [1, seqLen, config.hiddenDim]
            let activation = distributedRecv(
                shape: activationShape, dtype: .bfloat16,
                from: 0, group: group)
            eval(activation)

            // 3. Run rank 1's forward shard + lm_head.
            let logits = model.callPartial(
                activation,
                layerRange: config.rank1Range,
                applyEmbedding: false,
                applyNorm: true,
                applyHead: true,
                cache: isPrefill ? nil : cache)

            // Argmax over last token position only: [1, seqLen, vocab] → [1]
            let lastLogits = logits[0..., -1, 0...]  // [1, vocab]
            let tokenId = lastLogits.argMax(axis: -1)  // [1]
            eval(tokenId)
            isPrefill = false

            // 4. Send token ID back to rank 0.
            let sentToken = tokenId.distributedSend(to: 0, group: group)
            eval(sentToken)
        }
    }
}
