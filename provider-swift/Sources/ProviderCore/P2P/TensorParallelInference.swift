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
// STATUS: scaffold only. The cluster runtime is currently a stub
// (see ClusterCommand.swift line 431 — "Integrate ... with the coordinator
// request queue"). Wiring the engine into the live inference loop, jaccl
// DistributedGroup initialization, and the rank-1 serve loop are tracked
// for a follow-up. This file defines the API shape so the dispatcher and
// tests have something concrete to target.

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

// MARK: - TensorParallelEngine (rank 0)

/// Drives tensor-parallel inference from rank 0's perspective.
///
/// Both ranks load `LlamaModelTP` and call `model.callAsFunction(input)` in
/// lockstep; the sharded linear layers internally allreduce activations via
/// the `DistributedGroup`. Both ranks produce identical logits; rank 0
/// samples the next token and streams it to the consumer, then signals
/// rank 1 to advance.
///
/// On a singleton group (worldSize=1), this degenerates to ordinary
/// single-rank inference — the sharded layers' allreduce is a no-op.
///
/// On link failure, each step is retried up to 3 times with a 3-second
/// delay (mirrors EncryptedPipelineEngine semantics). After 3 consecutive
/// failures, `ClusterError.serviceUnavailable` is thrown.
public actor TensorParallelEngine {
    private let config: TensorParallelConfig
    /// Held as `any LLMModel` so callers can pass either the fp16 variant
    /// (`LlamaModelTP`) or the quantized variant (`LlamaModelTPQ`) without
    /// the engine needing to be templated on the concrete type. Callers
    /// (typically the dispatcher in `ClusterDiscovery`) are responsible
    /// for passing a TP-capable model — passing a non-TP `LlamaModel`
    /// would type-check but produce single-rank semantics.
    private let model: any LLMModel
    private let tokenizer: any Tokenizer
    private var cache: [any KVCache]
    private let session: ClusterSession

    private let logger = Logger(
        subsystem: "io.darkbloom.provider", category: "TensorParallelEngine")

    public init(
        config: TensorParallelConfig,
        model: any LLMModel,
        tokenizer: any Tokenizer,
        session: ClusterSession
    ) {
        self.config = config
        self.model = model
        self.tokenizer = tokenizer
        self.session = session
        self.cache = []
        logger.info(
            """
            TensorParallelEngine initialized: layers=\(config.numLayers), \
            hidden=\(config.hiddenDim), vocab=\(config.vocabSize), \
            worldSize=\(config.worldSize)
            """)
    }

    /// Reset the KV cache to a fresh state. Called between distinct requests.
    public func resetCache() {
        cache = model.newCache(parameters: nil)
        logger.info("TP KV cache reset (per-rank shard of \(self.cache.count) layers)")
    }

    // The actual decode loop is intentionally NOT implemented here yet —
    // it depends on the cluster runtime integration that's still a stub
    // in ClusterCommand.swift. The shape will be:
    //
    //   func generate(prompt: [Int], maxTokens: Int) -> AsyncStream<Int> {
    //       AsyncStream { continuation in
    //           Task {
    //               // 1. Send prompt token IDs to rank 1 over ThunderboltLink.
    //               // 2. Both ranks call model.callAsFunction (synced via allreduce).
    //               // 3. Rank 0 samples token from logits, yields to consumer.
    //               // 4. Rank 0 signals rank 1 with the chosen token + "continue".
    //               // 5. Repeat until EOS or maxTokens.
    //           }
    //       }
    //   }
}

// MARK: - TensorParallelServer (rank 1)

/// Drives the rank-1 side of tensor-parallel inference. Symmetric to rank 0
/// — both ranks run `model.callAsFunction(input)` in lockstep with allreduce
/// synchronization. Rank 1 doesn't sample; it just provides compute for the
/// allreduces and waits for rank 0's "next input" / "session end" signals
/// over the ThunderboltLink control channel.
public actor TensorParallelServer {
    private let config: TensorParallelConfig
    /// See `TensorParallelEngine.model` — same polymorphism rationale.
    private let model: any LLMModel
    private let peer: ClusterPeer

    private let logger = Logger(
        subsystem: "io.darkbloom.provider", category: "TensorParallelServer")

    public init(
        config: TensorParallelConfig,
        model: any LLMModel,
        peer: ClusterPeer
    ) {
        self.config = config
        self.model = model
        self.peer = peer
        logger.info(
            "TensorParallelServer initialized: layers=\(config.numLayers), worldSize=\(config.worldSize)"
        )
    }

    // Same stub status as TensorParallelEngine — the serve loop will be:
    //
    //   func serve() async throws {
    //       try await peer.serve(modelState: ..., inferenceHandler: { conn, _, _ in
    //           // Loop:
    //           //   Receive input token IDs from rank 0.
    //           //   model.callAsFunction(input, cache) — synced via allreduce.
    //           //   Receive sampled token from rank 0; advance cache.
    //           //   On sessionEnd, exit loop.
    //       })
    //   }
}
