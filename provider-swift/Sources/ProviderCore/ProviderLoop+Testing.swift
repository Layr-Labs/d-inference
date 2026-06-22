/// ProviderLoop -- test-only seams.
///
/// Internal accessors used exclusively by ProviderCoreTests (via
/// `@testable import`) to drive otherwise-private flows without the real
/// coordinator event loop or download path. Not used by production code.

import CryptoKit
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXLMServer
import MLXVLM
#if canImport(os)
import os
#endif

extension ProviderLoop {
    /// Test seam: number of advertised models (startup ∪ prefetched).
    func advertisedModelCount() -> Int { advertisedModels.count }

    /// Test seam: whether a model id is currently advertised.
    func isModelAdvertised(_ id: String) -> Bool { advertisedModels[id] != nil }

    /// Test seam: recorded weight hash for a model (nil when unknown).
    func modelHashForTesting(_ id: String) -> String? { modelHashes[id] }

    /// Test seam: exposes the prefetch pre-check decision.
    func prefetchPreCheckForTesting(_ id: String) -> PrefetchPreCheck { prefetchPreCheck(modelId: id) }

    /// Test seam: drive the declarative `desired_models` reconcile directly (the
    /// real entry point, `reconcileDesiredModels`, is private and otherwise only
    /// reached via the coordinator event loop). Lets a unit test prove that a
    /// desired build the provider lacks triggers a prefetch, and that the
    /// previous build is recorded for the hard-swap drop.
    func reconcileDesiredModelsForTesting(_ entries: [CoordinatorMessage.DesiredModelEntry], send: SendHandle) async {
        await reconcileDesiredModels(entries, send: send)
    }

    /// Test seam: the current effective concurrent-slot cap (tracks the live
    /// advertised set, clamped to `[1, backend.maxModelSlots]`).
    func maxModelSlotsForTesting() -> Int { maxModelSlots }

    /// Test seam: override the desired-build prefetch retry backoff schedule
    /// (the production default waits tens of seconds between attempts).
    func setDesiredPrefetchRetryDelaysForTesting(_ delays: [Duration]) {
        desiredPrefetchRetryDelays = delays
    }

    /// Test seam: number of scheduled (not yet fired) desired-prefetch retries.
    func pendingDesiredPrefetchRetriesForTesting() -> Int { desiredPrefetchRetryTasks.count }

    /// Test seam: install a fake prefetcher and (re)build the prefetch
    /// coordinator against a given coordinator client. Used by unit tests to
    /// exercise the handler without the real download path.
    func installPrefetchCoordinatorForTesting(
        _ coordinator: ModelPrefetchCoordinator,
        client: CoordinatorClient,
        send: SendHandle? = nil
    ) {
        self.coordinatorClient = client
        self.prefetchCoordinator = coordinator
        if let send { self.outboundSend = send }
    }

}
