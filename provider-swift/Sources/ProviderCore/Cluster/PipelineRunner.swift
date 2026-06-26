/// PipelineRunner -- the full multi-token greedy decode loop over a pipeline.
///
/// Each rank runs THIS loop with its own `PipelineModelShard` + `PipelineStage`.
/// Per decode step the hidden state flows head→…→tail (sealed activations over
/// the ring), the tail samples the next token, and that token is broadcast back
/// so the head can embed it for the next step. The loop ends on EOS or
/// `maxTokens`. Sampled tokens are delivered through `onToken` as they are
/// produced (the tail produces them; on other ranks they arrive via the token
/// broadcast so every rank can stay in lockstep and stop together).
///
/// Greedy only for the PoC (argmax); temperature/top-p sampling is a later add.
/// The token broadcast is abstracted via `TokenChannel` — loopback in tests,
/// MLX `all_gather` on hardware.

import Foundation
import MLX

/// Broadcasts the just-sampled token id from the tail to all ranks each step.
public protocol TokenChannel: Sendable {
    /// Tail publishes the sampled token for `step`.
    func publish(token: Int, step: Int) async throws
    /// Non-tail ranks await the token for `step`.
    func receive(step: Int) async throws -> Int
}

public struct PipelineRunConfig: Sendable {
    public let clusterId: String
    public let requestId: String
    public let maxTokens: Int
    public let eosTokenIds: Set<Int>
    public init(clusterId: String, requestId: String, maxTokens: Int, eosTokenIds: Set<Int>) {
        self.clusterId = clusterId
        self.requestId = requestId
        self.maxTokens = maxTokens
        self.eosTokenIds = eosTokenIds
    }
}

public struct PipelineRunner {
    let shard: any PipelineModelShard
    let stage: PipelineStage
    let tokens: any TokenChannel
    let config: PipelineRunConfig

    public init(
        shard: any PipelineModelShard,
        stage: PipelineStage,
        tokens: any TokenChannel,
        config: PipelineRunConfig
    ) {
        self.shard = shard
        self.stage = stage
        self.tokens = tokens
        self.config = config
    }

    /// Run greedy decode. `promptTokens` is the tokenized prompt (used by the
    /// head to embed; other ranks ignore it). `onToken` is called once per
    /// generated token id, in order, on every rank.
    public func run(promptTokens: [Int], onToken: (Int) async -> Void) async throws {
        var generated: [Int] = []

        for step in 0..<config.maxTokens {
            // Head embeds the running sequence (prompt + generated so far).
            let headInput: MLXArray? = shard.isHead
                ? shard.embed(tokens: promptTokens + generated)
                : nil

            // One forward step through this rank's layers, with sealed ring
            // hand-off. Tail gets the post-layer hidden state back to project.
            // The stage builds per-hop AEAD contexts internally (bound to the
            // sender rank) so inbound/outbound hops authenticate correctly.
            let stageOut = try await stage.runStep(
                headInput: headInput,
                clusterId: config.clusterId,
                requestId: config.requestId,
                seq: UInt64(step),
                runLayers: { shard.runOwnedLayers($0) })

            // Determine the next token.
            let nextToken: Int
            if shard.isTail {
                guard let hidden = stageOut else { return }   // defensive
                let logits = shard.projectToLogits(hidden)
                nextToken = Self.greedyToken(logits)
                try await tokens.publish(token: nextToken, step: step)
            } else {
                nextToken = try await tokens.receive(step: step)
            }

            generated.append(nextToken)
            await onToken(nextToken)
            if config.eosTokenIds.contains(nextToken) { break }
        }
    }

    /// Argmax over the last position's vocabulary logits.
    static func greedyToken(_ logits: MLXArray) -> Int {
        // logits shape is [..., vocab]; take argmax over the final axis and
        // read the last position if a sequence axis is present.
        let lastAxis = logits.ndim - 1
        let ids = argMax(logits, axis: lastAxis)
        ids.eval()
        // ids has the logits' shape minus the vocab axis; the final scalar is
        // the most-recent position's predicted token.
        let flat = ids.asArray(Int32.self)
        return Int(flat.last ?? 0)
    }
}
