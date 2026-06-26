/// InferenceEngine -- the abstraction seam that lets a *distributed* engine
/// stand in where the single-process `BatchScheduler` is used today.
///
/// Today `ProviderLoop` owns a concrete `BatchScheduler`. To run a model across
/// a cluster (pipeline parallelism), the head node needs an engine with the
/// same surface that internally fans the forward pass across ring neighbors.
/// This protocol is that surface -- intentionally the minimal subset of
/// `BatchScheduler`'s public API the provider loop relies on -- so that:
///   - `BatchScheduler` conforms unchanged (single-node, the default), and
///   - `DistributedInferenceEngine` conforms for cluster mode.
///
/// See docs/architecture/clustering.md §5 (engine binding row).

import Foundation
import MLXLMCommon

public protocol InferenceEngine: Actor {
    /// Load (or replace) the resident model.
    func loadModel(container: ModelContainer, modelId: String, weightHash: String?) async

    /// Submit a chat request; returns a stream of generation events.
    func submit(request: ChatCompletionRequest, requestId: String?) async -> AsyncStream<GenerationEvent>

    /// Cancel an in-flight request.
    func cancel(requestId: String) async

    /// Current capacity snapshot (slots, token budget, decode TPS, ...).
    func capacity() -> SchedulerCapacity
}

// MARK: - BatchScheduler conformance

/// `BatchScheduler` already implements every requirement (matching argument
/// labels and defaults). The conformance is declared here, in the cluster
/// module, so the single-node scheduler file is not touched -- a surgical,
/// behavior-preserving addition (the protocol just names methods it already
/// has).
extension BatchScheduler: InferenceEngine {}
