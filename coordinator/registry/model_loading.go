package registry

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry/modelloads"
)

const pendingModelLoadTTL = modelloads.PendingTTL

const pendingModelLoadDrainBackoff = modelloads.DrainBackoff

const pendingModelLoadMemoryBackoff = modelloads.MemoryBackoff

type modelLoadAction struct {
	providerID string
	modelID    string
}

// TriggerModelSwaps checks for queued requests that have no warm provider
// and sends load_model to cold providers that have the model available on
// disk. This enables demand-driven model swapping: when requests queue for
// a model that no provider has warm, the coordinator proactively triggers
// a swap on an idle provider.
//
// Called after heartbeat processing and queue drain to catch demand that
// can't be satisfied by warm providers alone.
func (r *Registry) TriggerModelSwaps() {
	queue := r.Queue()
	if queue == nil {
		return
	}

	queuedModels := queue.QueuedModels()
	if len(queuedModels) == 0 {
		return
	}

	now := time.Now()
	r.expirePendingModelLoads(now)

	actions := r.planModelLoadActions(queuedModels, now)
	actions = r.reservePendingModelLoads(actions, now)
	r.sendModelLoadActions(actions)
}

// BackoffPendingModelLoadForDrain re-stamps a pending load entry with the
// short drain backoff. Called when a provider rejects load_model because it
// is draining ahead of an auto-update restart: clearing the entry outright
// would re-send load_model to the same draining provider on the very next
// TriggerModelSwaps pass, while the full failure cooldown would suppress the
// provider long after a failed restart resumed serving. A successful restart
// clears the entry anyway via Disconnect.
func (r *Registry) BackoffPendingModelLoadForDrain(providerID, modelID string) {
	r.backoffPendingModelLoad(providerID, modelID, pendingModelLoadDrainBackoff)
}

// BackoffPendingModelLoadForMemory re-stamps a pending load entry with the
// short memory backoff after a NON-draining load_model failure (see
// pendingModelLoadMemoryBackoff). Memory-pressure load failures recover in
// seconds, so the entry must not keep the provider unplannable for the full
// pendingModelLoadTTL — that window (~2 min) is ≈ the 120s queue timeout, so a
// request queued right after the failure would time out before the provider is
// reconsidered by TriggerModelSwaps. The ~10s warm-pool sweep reaps the
// re-stamped entry.
func (r *Registry) BackoffPendingModelLoadForMemory(providerID, modelID string) {
	r.backoffPendingModelLoad(providerID, modelID, pendingModelLoadMemoryBackoff)
}
