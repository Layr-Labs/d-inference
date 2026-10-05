package registry

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/pendingload"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// pendingModelLoadTTL bounds how long an outstanding (or failed) load_model
// suppresses re-sends to the same provider.
const pendingModelLoadTTL = pendingload.TTL

// pendingModelLoadDrainBackoff is the short cooldown used when a provider
// rejects load_model because it is draining for an auto-update restart. The
// entry keeps the planner away from a provider that is about to bounce, but
// must not outlive a failed restart: if the provider aborts the restart and
// resumes serving, it is fully loadable again, and the full 2-minute cooldown
// would strand queued requests that this provider (or its post-restart
// re-registration) could serve.
const pendingModelLoadDrainBackoff = pendingload.DrainBackoff

// pendingModelLoadMemoryBackoff is the short cooldown used when a proactive
// load_model fails for a NON-draining reason — dominated by transient memory
// pressure (insufficient free memory / KV headroom) that frees within seconds
// as in-flight requests on other slots finish. Leaving the full
// pendingModelLoadTTL (2 min, ≈ the 120s request-queue timeout) would suppress
// proactive re-loads to this provider long enough that a request which queues
// right after the failure times out before the provider is reconsidered, even
// though its memory may have freed almost immediately. Kept equal to the drain
// backoff today but named separately so the two can diverge. The ~10s warm-pool
// sweep reaps the re-stamped entry deterministically.
const pendingModelLoadMemoryBackoff = pendingload.MemoryBackoff

// ModelLoadAction is a planned command with an opaque session-bound reservation.
type ModelLoadAction struct {
	ProviderID  string `json:"-"`
	ModelID     string `json:"-"`
	reservation pendingModelLoadSendAttempt
}

type modelLoadAction = ModelLoadAction

func (r *Registry) RecordDispatchLoadFailure(providerID, modelID string) bool {
	return r.gates.RecordDispatchLoadFailure(providerID, modelID)
}

func (r *Registry) ClearDispatchLoadCooldown(providerID, modelID string) {
	r.gates.ClearDispatchLoadCooldown(providerID, modelID)
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
	// An active controller owns warming, including queue-triggered demand. A
	// second planner would bypass its global budgets and dwell policy.
	r.mu.RLock()
	controller := r.warmPool
	active := controller != nil && controller.config.ActivePlanner()
	r.mu.RUnlock()
	if active {
		r.RequestWarmPoolTrigger()
		return
	}
	queue := r.Queue()
	if queue == nil {
		return
	}

	queuedModels := queue.QueuedModels()
	if len(queuedModels) == 0 {
		return
	}

	now := time.Now()
	r.modelLoadPlanner.Expire(now)

	actions := r.modelLoadPlanner.Plan(queuedModels, now)
	actions = r.modelLoadPlanner.Reserve(actions, now)
	r.modelLoadPlanner.Send(actions)
}

func (r *Registry) expirePendingModelLoads(now time.Time) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.pendingLoads.Expire(now, func(key pendingload.Key) {
		r.recordDeadlineLoadActivityLocked(key.ProviderID, now)
	})
}

// hasWarmProviderLocked reports whether a connected provider already has the
// model warm. Caller must hold r.mu (read or write).
func (r *Registry) hasWarmProviderLocked(model string, now time.Time) bool {
	// Only advertisers can hold the model warm (warm/slot reports are
	// canonicalized against p.Models; providerHasWarmModelLocked also requires
	// providerServesRoutableModelLocked), so the per-model index prunes the
	// walk losslessly (model_index.go).
	for _, p := range r.providersForModelLocked(model) {
		p.mu.Lock()
		warm := r.providerHasWarmModelLocked(p, model, now)
		p.mu.Unlock()
		if warm {
			return true
		}
	}
	return false
}

// providerHasWarmModelLocked checks whether the provider has the model warm
// AND passes the same routing safety gates used by the scheduler. A provider
// with stale attestation or failed privacy checks should not suppress swap
// planning. Caller must hold p.mu. Caller must hold r.mu (read or write).
func (r *Registry) providerHasWarmModelLocked(p *Provider, model string, now time.Time) bool {
	return (&ModelLoadPreparation{registry: r}).warmLocked(p, model, now)
}

func (r *Registry) reservePendingModelLoads(actions []modelLoadAction, now time.Time) []modelLoadAction {
	if len(actions) == 0 {
		return nil
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	reserved := actions[:0]
	for _, action := range actions {
		if p, ok := r.providers[action.ProviderID]; ok {
			p.mu.Lock()
			eligible := !providerLegacyModelChangesBlockedLocked(p) && p.warmLifecycleLocked().CanLoad(now) && r.providerCanAcquireCatalogModelLocked(p, action.ModelID)
			p.mu.Unlock()
			if !eligible {
				continue
			}
		}
		// Check per-provider (not just per-key) to prevent concurrent
		// heartbeat goroutines from reserving the same idle provider
		// for different models.
		if r.providerHasPendingLoad(action.ProviderID) {
			continue
		}
		key := pendingload.Key{ProviderID: action.ProviderID, ModelID: action.ModelID}
		r.recordDeadlineLoadActivityLocked(action.ProviderID, now)
		reservation := r.pendingLoads.Reserve(key, now.Add(pendingModelLoadTTL), now)
		action.reservation = pendingModelLoadSendAttempt{
			provider: r.providers[action.ProviderID], timing: reservation,
		}
		reserved = append(reserved, action)
	}
	return reserved
}

func (r *Registry) sendModelLoadActions(actions []modelLoadAction) {
	for _, action := range actions {
		if !r.modelLoadSendStillPending(action) {
			continue
		}
		if err := r.SendLoadModel(action.ProviderID, action.ModelID); err != nil {
			r.logger.Warn("failed to trigger model swap",
				"provider_id", action.ProviderID,
				"model_id", action.ModelID,
				"error", err,
			)
			r.failPendingModelLoadSend(action)
		}
	}
}

// providerHasPendingLoad reports whether the provider has any pending
// load_model command. Caller must hold r.mu (read or write).
func (r *Registry) providerHasPendingLoad(providerID string) bool {
	return r.pendingLoads.HasProvider(providerID)
}

// ClearIneligiblePendingModelLoads releases warm-pool reservations whose
// provider/model pair no longer passes the command-side catalog and capability
// gate. Runtime-policy revocation calls this after capability reconciliation so
// stale protected loads cannot consume the global pending-load budget.
func (r *Registry) ClearIneligiblePendingModelLoads(providerID string) int {
	r.mu.Lock()
	p, ok := r.providers[providerID]
	if !ok {
		r.mu.Unlock()
		return 0
	}
	p.mu.Lock()

	cleared := r.pendingLoads.DropIf(func(key pendingload.Key) bool {
		if key.ProviderID != providerID || key.ModelID == "" {
			return false
		}
		return !r.providerCanAcquireCatalogModelLocked(p, key.ModelID)
	}, func(pendingload.Key) {
		p.recordDeadlineActivityLocked(time.Now())
	})
	p.mu.Unlock()
	r.mu.Unlock()
	if cleared > 0 {
		r.RequestWarmPoolTrigger()
	}
	return cleared
}

// MarkModelWarm records a successful placement and fills any warm state not yet
// reported by heartbeat, so queue drain sees the loaded model immediately.
func (r *Registry) MarkModelWarm(providerID, modelID string) {
	r.mu.RLock()
	p, ok := r.providers[providerID]
	if !ok {
		r.mu.RUnlock()
		return
	}
	p.mu.Lock()
	if !r.providerServesCatalogModelLocked(p, modelID) {
		p.mu.Unlock()
		r.mu.RUnlock()
		return
	}
	defer func() {
		p.mu.Unlock()
		r.mu.RUnlock()
	}()
	// A completion heartbeat can report the loaded slot before its succeeded
	// status arrives. The successful placement still starts dwell in that order;
	// the early return only avoids rewriting already-authoritative warm state.
	p.warmLifecycleLocked().Place(time.Now())
	for _, wm := range p.WarmModels {
		if wm == modelID {
			return // already warm
		}
	}
	p.WarmModels = append(p.WarmModels, modelID)
	p.CurrentModel = modelID

	// Inject a synthetic "idle" slot into BackendCapacity so the scheduler
	// sees the model as warm. Without this, the scheduler only checks
	// BackendCapacity.Slots (not WarmModels) for Swift providers, and a
	// stale snapshot without the new model's slot would treat it as cold
	// until the next heartbeat arrives.
	//
	// We only add/update the new model's slot and leave existing slots
	// untouched — the provider may have multiple model slots loaded
	// simultaneously (maxModelSlots defaults to 3). The next heartbeat
	// will provide the authoritative slot list.
	if p.BackendCapacity != nil {
		found := false
		for i, slot := range p.BackendCapacity.Slots {
			if slot.Model == modelID {
				p.BackendCapacity.Slots[i].State = "idle"
				found = true
				break
			}
		}
		if !found {
			p.BackendCapacity.Slots = append(p.BackendCapacity.Slots, protocol.BackendSlotCapacity{
				Model: modelID,
				State: "idle",
			})
		}
	}
}

// ClearPendingModelLoad removes a pending model load entry after a terminal
// load_model_status response. The active planner must observe
// the freed global budget even if its earlier heartbeat trigger saw it full.
func (r *Registry) ClearPendingModelLoad(providerID, modelID string) time.Duration {
	r.mu.Lock()
	key := pendingload.Key{ProviderID: providerID, ModelID: modelID}
	reservation, released := r.pendingLoads.Lookup(key)
	if released {
		r.recordDeadlineLoadActivityLocked(providerID, time.Now())
	}
	r.pendingLoads.Drop(key)
	r.mu.Unlock()
	if released {
		r.RequestWarmPoolTrigger()
	}
	if reservation.StartedAt.IsZero() {
		return 0
	}
	return time.Since(reservation.StartedAt)
}

func (r *Registry) PendingModelLoadDuration(providerID, modelID string) time.Duration {
	r.mu.RLock()
	reservation, _ := r.pendingLoads.Lookup(pendingload.Key{ProviderID: providerID, ModelID: modelID})
	r.mu.RUnlock()
	if reservation.StartedAt.IsZero() {
		return 0
	}
	return time.Since(reservation.StartedAt)
}

// HasPendingModelLoad reports whether an unexpired coordinator-issued
// load_model command exists for exactly this provider/model pair. It lets the
// WebSocket boundary reject unsolicited load_model_status messages before
// allowing them to mutate warm-model state.
func (r *Registry) HasPendingModelLoad(providerID, modelID string) bool {
	r.mu.RLock()
	reservation, ok := r.pendingLoads.Lookup(pendingload.Key{ProviderID: providerID, ModelID: modelID})
	r.mu.RUnlock()
	return ok && time.Now().Before(reservation.ExpiresAt)
}

// backoffPendingModelLoad re-stamps a pending load entry's expiry to
// now+backoff, seeding the start time when this is the first time the
// pair is seen (the coordinator may learn of a rejection for a load_model whose
// reservation already expired or was cleared). Shared by the drain and
// memory/generic-failure backoff paths so a failed load is reconsidered after a
// short cooldown instead of the full pendingModelLoadTTL. Caller must NOT hold
// r.mu.
func (r *Registry) backoffPendingModelLoad(providerID, modelID string, backoff time.Duration) {
	r.mu.Lock()
	defer r.mu.Unlock()
	key := pendingload.Key{ProviderID: providerID, ModelID: modelID}
	now := time.Now()
	r.recordDeadlineLoadActivityLocked(providerID, now)
	r.pendingLoads.Backoff(key, now, backoff)
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

// RejectUnservableQueuedRequests checks whether any eligible provider can
// serve the given model. If not, all queued requests for the model are
// rejected immediately rather than waiting for the 120s queue timeout.
// Called after a load_model failure to give consumers a fast error.
func (r *Registry) RejectUnservableQueuedRequests(modelID string) {
	queue := r.Queue()
	if queue == nil {
		return
	}
	if queue.QueueSize(modelID) == 0 {
		return
	}

	// Check if any provider can still serve this model. Only reject when
	// NO provider serves the model at all. If providers exist but are
	// temporarily at capacity (capacityRejections > 0), the requests
	// should wait — those providers may finish current work and become
	// available.
	// modelTooLarge is intentionally ignored here: a model that can never fit
	// any provider should NOT keep its queued requests waiting (they'd time out
	// after 120s) — fall through to fail them fast.
	// Base-shape check: "can any provider serve this model at all?" carries no
	// tool/vision constraint, so use the default (base) traits.
	candidates, capacityRejections, _ := r.QuickCapacityCheck(modelID, 500, defaultRequestedMaxTokens, RequestTraits{})
	if candidates > 0 || capacityRejections > 0 {
		return
	}

	// Prefer waiters are preserved only when their owner actually has an owned
	// provider serving this model (it may free up). A prefer waiter with no
	// owned provider is just waiting on the (now-unservable) public fleet, so it
	// should fail fast like any public request. Compute eligibility here —
	// OUTSIDE the queue lock — since OwnedProviderSummary takes the registry lock.
	preferOwnerEligible := make(map[string]bool)
	for _, owner := range queue.PreferWaiterOwners(modelID) {
		// Base-shape question (like the QuickCapacityCheck above): does the
		// owner have ANY box serving this model — no per-request trait/vision
		// constraint at this granularity.
		_, servesModel := r.OwnedProviderSummary(owner, modelID, RequestTraits{}, false)
		preferOwnerEligible[owner] = servesModel > 0
	}

	failed := queue.FailQueuedRequestsForModel(modelID, preferOwnerEligible)
	if failed > 0 {
		r.logger.Warn("rejected queued requests for unservable model",
			"model_id", modelID,
			"rejected", failed,
		)
	}
}
