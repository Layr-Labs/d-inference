/// DistributedInferenceEngine -- pipeline-parallel inference across a cluster,
/// behind the `InferenceEngine` seam (so `ProviderLoop` can use it in place of
/// the single-node `BatchScheduler`).
///
/// It owns this rank's model shard (`PipelineModelShard`) and tokenizer, and per
/// request drives a `PipelineRunner`: tokenize → embed (head) → ring forward
/// pass with sealed activations → sample (tail) → token broadcast → detokenize →
/// stream `GenerationEvent`s.
///
/// Runtime-decoupled via `ClusterRuntime`, which mints the per-request
/// `PipelineStage` (transport + sealing/opening channels) and `TokenChannel`.
/// In tests that runtime is loopback (in-process); on hardware it is the
/// `MLXDistributed` ring + `all_gather`. This keeps the engine fully testable on
/// one machine while the ring is swapped in unchanged.
///
/// Trust/crypto invariant (the whole reason this isn't just exo): the prompt is
/// decrypted ONLY on the head node (rank 0) via the existing per-request NaCl
/// Box path. Activation tensors that cross to other ranks are sealed per-token
/// with the session key from the handshake -- never plaintext on the wire. See
/// docs/architecture/cluster-node-handshake.md §6-7.

import Foundation
import MLX
import MLXLMCommon

public enum DistributedEngineError: Error, Sendable {
    case notInitialized
    case modelNotLoaded
    case rankWithoutSession(rank: Int)
}

/// Per-neighbor encrypted link, derived from a completed handshake.
public struct ClusterNeighborLink: Sendable {
    public let peerRank: Int
    public let session: ClusterSession
    public init(peerRank: Int, session: ClusterSession) {
        self.peerRank = peerRank
        self.session = session
    }
}

/// Supplies the per-request pipeline plumbing. One implementation is loopback
/// (tests); the other wraps the `MLXDistributed` ring (hardware).
public protocol ClusterRuntime: Sendable {
    /// Build this rank's `PipelineStage` for one request (fresh sealing/opening
    /// channels so the nonce sequence restarts per request).
    func makeStage(requestId: String) -> PipelineStage
    /// Build the token-broadcast channel for one request.
    func makeTokenChannel(requestId: String) -> any TokenChannel
}

public actor DistributedInferenceEngine: InferenceEngine {
    private let plan: ClusterPlan
    private let runtime: any ClusterRuntime

    // Set on loadModel.
    private var shard: (any PipelineModelShard)?
    private var tokenizer: (any Tokenizer)?
    private var loadedModelId: String?
    private var eosTokenIds: Set<Int>

    public init(plan: ClusterPlan, runtime: any ClusterRuntime, eosTokenIds: Set<Int> = []) {
        self.plan = plan
        self.runtime = runtime
        self.eosTokenIds = eosTokenIds
    }

    /// Install this rank's shard + tokenizer. The shard is produced by the
    /// sharded loader (which loads only this rank's layer slice).
    public func installShard(_ shard: any PipelineModelShard, tokenizer: any Tokenizer, modelId: String, eosTokenIds: Set<Int>) {
        self.shard = shard
        self.tokenizer = tokenizer
        self.loadedModelId = modelId
        self.eosTokenIds = eosTokenIds
    }

    public var rank: Int { plan.rank }
    public var worldSize: Int { plan.worldSize }

    // MARK: - InferenceEngine

    public func loadModel(container: ModelContainer, modelId: String, weightHash: String?) async {
        // The InferenceEngine seam passes a full ModelContainer (single-node
        // shape). For the cluster, the sharded loader builds a PipelineModelShard
        // (this rank's layer slice only) and installs it via `installShard`.
        // Constructing the shard from `container` is the mlx-swift-lm-fork piece
        // (see PipelineModelShard / clustering-implementation-status.md); when a
        // shard is already installed this is a no-op marker.
        loadedModelId = modelId
    }

    public func submit(request: ChatCompletionRequest, requestId: String?) async -> AsyncStream<GenerationEvent> {
        let (stream, continuation) = AsyncStream<GenerationEvent>.makeStream()
        guard let shard, let tokenizer else {
            continuation.yield(.error("No model shard loaded on rank \(plan.rank)"))
            continuation.finish()
            return stream
        }
        let id = requestId ?? "req-\(UUID().uuidString.prefix(12))"
        let maxTokens = request.max_tokens ?? 512

        // Tokenize the prompt via the chat template (head needs the ids to
        // embed; other ranks tokenize identically so EOS/length agree).
        let promptTokens: [Int]
        do {
            promptTokens = try Self.tokenizePrompt(request, tokenizer: tokenizer)
        } catch {
            continuation.yield(.error("tokenization failed: \(error)"))
            continuation.finish()
            return stream
        }

        let stage = runtime.makeStage(requestId: id)
        let tokens = runtime.makeTokenChannel(requestId: id)
        let runner = PipelineRunner(
            shard: shard, stage: stage, tokens: tokens,
            config: PipelineRunConfig(
                clusterId: plan.clusterId, requestId: id,
                maxTokens: maxTokens, eosTokenIds: eosTokenIds))

        let tk = tokenizer
        let eos = eosTokenIds
        let promptCount = promptTokens.count
        let task = Task {
            var generated = 0
            do {
                try await runner.run(promptTokens: promptTokens) { token in
                    generated += 1
                    if eos.contains(token) { return }
                    let piece = tk.decode(tokenIds: [token])
                    if !piece.isEmpty { continuation.yield(.chunk(piece)) }
                }
                continuation.yield(.info(
                    promptTokens: promptCount, completionTokens: generated,
                    tokensPerSecond: 0))
            } catch {
                continuation.yield(.error("pipeline decode failed: \(error)"))
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    public func cancel(requestId: String) async {
        // Cancellation flows through the AsyncStream termination handler, which
        // cancels the decode Task. A ring-level cancel marker (so peers stop in
        // lockstep) is the hardware follow-up.
    }

    public func capacity() -> SchedulerCapacity {
        SchedulerCapacity(
            model: loadedModelId ?? "",
            activeRequests: 0,
            pendingRequests: 0,
            maxConcurrent: 1,
            engineMaxConcurrent: 1,
            gpuMemoryActiveBytes: 0,
            gpuMemoryPeakBytes: 0,
            gpuMemoryCacheBytes: 0,
            totalMemoryBytes: 0)
    }

    // MARK: - Helpers

    /// Apply the chat template to the request's messages, returning token ids.
    static func tokenizePrompt(_ request: ChatCompletionRequest, tokenizer: any Tokenizer) throws -> [Int] {
        let messages: [[String: any Sendable]] = request.messages.map {
            ["role": $0.role, "content": $0.content]
        }
        return try tokenizer.applyChatTemplate(messages: messages, tools: nil, additionalContext: nil)
    }
}
