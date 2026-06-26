/// PipelineStage -- one rank's half of a pipeline-parallel forward pass.
///
/// This is the Swift equivalent of exo's PipelineFirstLayer/PipelineLastLayer
/// wrapping (auto_parallel.py:132/158), with Darkbloom's encryption woven in:
///
///   rank 0 (head):  embed → run owned layers → SEAL+send hidden state
///   middle rank:    recv+OPEN → run owned layers → SEAL+send
///   last rank:      recv+OPEN → run owned layers → norm+lm_head → sample token
///
/// The "run owned layers" step is injected as a closure (`runLayers`) so the
/// stage logic — boundary recv/open, layer execution, seal/send, sequencing —
/// is unit-testable on ONE machine with a mock transform, and the SAME stage
/// drives the real model on hardware (the closure becomes the sliced
/// `LlamaModelInner` layer loop). The transport is likewise injected
/// (`PipelineTransport`), loopback locally / MLX-ring on two Macs.
///
/// Encryption boundary: a hidden state only ever leaves a rank as a sealed
/// `ActivationCodec` frame. `runLayers` operates on plaintext tensors strictly
/// inside the process. See docs/architecture/cluster-node-handshake.md §6.

import Foundation
import MLX

/// Per-rank inputs needed to run its slice of the pipeline.
public struct PipelineStageConfig: Sendable {
    public let rank: Int
    public let worldSize: Int
    public let interval: LayerInterval
    /// Ring neighbors. nil at the ends of a non-wrapping pipeline.
    public let prevRank: Int?
    public let nextRank: Int?

    public var isHead: Bool { rank == 0 }
    public var isTail: Bool { rank == worldSize - 1 }

    public init(rank: Int, worldSize: Int, interval: LayerInterval, prevRank: Int?, nextRank: Int?) {
        self.rank = rank
        self.worldSize = worldSize
        self.interval = interval
        self.prevRank = prevRank
        self.nextRank = nextRank
    }
}

public enum PipelineStageError: Error, Sendable {
    case headMissingInput
    case missingNeighbor(String)
    case notTail
}

/// Drives one decode step (one token) through this rank's layers.
public struct PipelineStage {
    let config: PipelineStageConfig
    let transport: any PipelineTransport
    /// Seal frames going to `nextRank`. nil on the tail.
    let sealing: ClusterSealingChannel?
    /// Open frames coming from `prevRank`. nil on the head.
    let opening: ClusterOpeningChannel?

    public init(
        config: PipelineStageConfig,
        transport: any PipelineTransport,
        sealing: ClusterSealingChannel?,
        opening: ClusterOpeningChannel?
    ) {
        self.config = config
        self.transport = transport
        self.sealing = sealing
        self.opening = opening
    }

    /// Run this rank's slice for one step.
    ///
    /// - Parameters:
    ///   - headInput: the hidden state to start from (head only — typically the
    ///     embedded tokens). Ignored on non-head ranks (they receive it).
    ///   - clusterId/requestId: AEAD binding for this request.
    ///   - seq: monotonic step index; must match the channel nonce counters.
    ///   - runLayers: execute this rank's owned layers on a hidden state,
    ///     returning the transformed hidden state. On the tail this closure
    ///     should also apply final norm + lm_head and return logits.
    /// - Returns: on the tail, the final tensor (logits) for sampling; on
    ///   non-tail ranks, nil (their output was sent downstream).
    ///
    /// AAD hop binding: each frame's `layerRange` is set to the SENDER's rank
    /// (`hop-<rank>`). A receiver opens with the sender's id, which it knows is
    /// its own `prevRank`. This makes the AAD agree across each hop's two ends
    /// while differing between the inbound and outbound hops of a middle rank.
    public func runStep(
        headInput: MLXArray?,
        clusterId: String,
        requestId: String,
        seq: UInt64,
        runLayers: (MLXArray) throws -> MLXArray
    ) async throws -> MLXArray? {
        // 1. Obtain the inbound hidden state.
        let inbound: MLXArray
        if config.isHead {
            guard let headInput else { throw PipelineStageError.headMissingInput }
            inbound = headInput
        } else {
            guard let opening, let prev = config.prevRank else {
                throw PipelineStageError.missingNeighbor("prev")
            }
            let inboundCtx = Self.hopContext(clusterId: clusterId, requestId: requestId, senderRank: prev, seq: seq)
            let sealedFrame = try await transport.recv(from: prev)
            let plaintextBytes = try opening.open(sealedFrame, context: inboundCtx)
            inbound = try ActivationCodec.decode(plaintextBytes)
        }

        // 2. Run owned layers (plaintext, in-process).
        let outbound = try runLayers(inbound)

        // 3. Tail returns logits for sampling; others seal+send downstream.
        if config.isTail {
            return outbound
        }
        guard let sealing, let next = config.nextRank else {
            throw PipelineStageError.missingNeighbor("next")
        }
        let outboundCtx = Self.hopContext(clusterId: clusterId, requestId: requestId, senderRank: config.rank, seq: seq)
        let frame = try sealing.seal(ActivationCodec.encode(outbound), context: outboundCtx)
        try await transport.send(frame, to: next)
        return nil
    }

    /// AEAD context for one hop, bound to the producing rank.
    static func hopContext(clusterId: String, requestId: String, senderRank: Int, seq: UInt64) -> ClusterFrameContext {
        ClusterFrameContext(clusterId: clusterId, requestId: requestId, layerRange: "hop-\(senderRank)", seq: seq)
    }
}
