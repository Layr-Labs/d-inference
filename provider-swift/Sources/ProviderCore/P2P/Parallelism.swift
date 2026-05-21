import Foundation

// MARK: - Parallelism
//
// Selects the model-split strategy for a cluster session. Operator-visible
// via the `--parallelism` flag on `darkbloom serve`. The default is `.auto`,
// which picks `.tp` when both cluster peers can support tensor parallelism
// for the loaded model, falls back to `.pp` when they can't, and falls back
// to `.single` when no cluster peer is available.
//
// Why `.tp` wins by default on 2-Mac Thunderbolt 5: both Macs run all
// transformer layers in parallel rather than taking turns, halving
// single-stream decode latency. The per-layer allreduce cost is negligible
// on TB5 (~80 Gbps, sub-ms per hidden-dim vector). PP stays as a fallback
// for non-Llama models (until they get *TP variants) and for clusters
// where the link bandwidth makes allreduces too expensive.

public enum Parallelism: String, Sendable, CustomStringConvertible {
    /// Tensor parallelism: both ranks run all layers in parallel; per-layer
    /// allreduce synchronizes activations. Requires a *TP model variant
    /// (e.g. `LlamaModelTP`).
    case tp

    /// Pipeline parallelism: rank 0 runs layers 0..N/2, rank 1 runs
    /// layers N/2..N. One activation transfer per token. Works for any
    /// model whose architecture exposes a layer-range entry point
    /// (i.e. `callPartial` on Llama).
    case pp

    /// No cluster: rank 0 runs the full model alone. The fallback when no
    /// peer is connected.
    case single

    /// Auto-select per `decide(...)`.
    case auto

    public var description: String { rawValue }
}

// MARK: - Decision

extension Parallelism {

    /// Inputs the dispatcher considers when `--parallelism auto` is set.
    public struct DecisionInputs: Sendable {
        public let operatorChoice: Parallelism
        /// Number of peers in the cluster (including self). 1 → single-rank.
        public let worldSize: Int
        /// True iff the loaded model has a published TP variant (e.g. Llama
        /// → true via `LlamaModelTP`). Other architectures fall back to PP
        /// until they get their own *TP variant.
        public let modelHasTPVariant: Bool
        /// `attentionHeads` of the loaded model. Used to check divisibility.
        public let attentionHeads: Int
        /// `kvHeads` of the loaded model. Used to check divisibility.
        public let kvHeads: Int
        /// True iff the underlying RDMA / jaccl backend is initialized and
        /// `DistributedGroup` can be created. False on macOS < 26.2, on
        /// pre-M5 hardware, or when `rdma_ctl` reports disabled.
        public let distributedGroupAvailable: Bool

        public init(
            operatorChoice: Parallelism,
            worldSize: Int,
            modelHasTPVariant: Bool,
            attentionHeads: Int,
            kvHeads: Int,
            distributedGroupAvailable: Bool
        ) {
            self.operatorChoice = operatorChoice
            self.worldSize = worldSize
            self.modelHasTPVariant = modelHasTPVariant
            self.attentionHeads = attentionHeads
            self.kvHeads = kvHeads
            self.distributedGroupAvailable = distributedGroupAvailable
        }
    }

    /// Pick the actual parallelism strategy from the operator's choice and
    /// the runtime capabilities. Honors explicit operator overrides as long
    /// as they're achievable; falls back with a reason when they aren't.
    ///
    /// Returns the chosen strategy and a short, operator-readable reason for
    /// the decision (suitable for logging at startup).
    public static func decide(_ inputs: DecisionInputs) -> (Parallelism, reason: String) {
        // worldSize=1 short-circuits everything: no cluster peer, no
        // parallelism. Operator can pass `--parallelism tp` and we'll still
        // end up here because there's no peer to be tensor-parallel with.
        if inputs.worldSize < 2 {
            return (.single, reason: "no cluster peer connected (worldSize=\(inputs.worldSize))")
        }

        switch inputs.operatorChoice {
        case .single:
            return (.single, reason: "operator selected --parallelism single")

        case .pp:
            return (.pp, reason: "operator selected --parallelism pp")

        case .tp:
            // Honor explicit TP if achievable. If not, fail closed rather than
            // silently downgrade — operator asked for TP for a reason.
            if !inputs.distributedGroupAvailable {
                return (
                    .single,
                    reason: "operator selected --parallelism tp but DistributedGroup unavailable (RDMA / M5 capability missing) — refusing to silently downgrade to PP, falling back to single-rank"
                )
            }
            if !inputs.modelHasTPVariant {
                return (
                    .single,
                    reason: "operator selected --parallelism tp but the loaded model has no TP variant — refusing to silently downgrade to PP, falling back to single-rank"
                )
            }
            if !canShard(heads: inputs.attentionHeads, worldSize: inputs.worldSize)
                || !canShard(heads: inputs.kvHeads, worldSize: inputs.worldSize)
            {
                return (
                    .single,
                    reason: "operator selected --parallelism tp but model heads don't divide evenly across worldSize=\(inputs.worldSize)"
                )
            }
            return (.tp, reason: "operator selected --parallelism tp; capabilities OK")

        case .auto:
            return autoDecide(inputs)
        }
    }

    private static func autoDecide(_ inputs: DecisionInputs) -> (Parallelism, reason: String) {
        // Auto: prefer TP if every capability lines up; else PP.
        if !inputs.distributedGroupAvailable {
            return (
                .pp,
                reason: "auto → pp: DistributedGroup unavailable (RDMA / M5 capability missing)"
            )
        }
        if !inputs.modelHasTPVariant {
            return (.pp, reason: "auto → pp: loaded model has no TP variant")
        }
        if !canShard(heads: inputs.attentionHeads, worldSize: inputs.worldSize)
            || !canShard(heads: inputs.kvHeads, worldSize: inputs.worldSize)
        {
            return (
                .pp,
                reason:
                    "auto → pp: model heads don't divide evenly across worldSize=\(inputs.worldSize) (attentionHeads=\(inputs.attentionHeads), kvHeads=\(inputs.kvHeads))"
            )
        }
        return (.tp, reason: "auto → tp: all capabilities OK")
    }

    /// True iff `heads` is positive and divides evenly across `worldSize`.
    public static func canShard(heads: Int, worldSize: Int) -> Bool {
        worldSize > 0 && heads > 0 && heads % worldSize == 0
    }
}
