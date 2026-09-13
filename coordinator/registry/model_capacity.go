package registry

import (
	"time"
)

// ModelCapacity describes the live capacity for a single model.
type ModelCapacity struct {
	ModelID              string  `json:"id"`
	Ready                bool    `json:"ready"`                  // at least one routable provider with headroom
	CanAccept            bool    `json:"can_accept"`             // ready AND queue not full
	RoutableProviders    int     `json:"routable_providers"`     // passed all gates
	WarmProviders        int     `json:"warm_providers"`         // model loaded (slot state "running" or "idle")
	RunningProviders     int     `json:"running_providers"`      // model loaded with active requests (slot state "running")
	ColdProviders        int     `json:"cold_providers"`         // model available but not loaded
	ActiveRequests       int     `json:"active_requests"`        // in-flight across fleet
	QueuedRequests       int     `json:"queued_requests"`        // waiting in coordinator queue
	QueueLimit           int     `json:"queue_limit"`            // max queue depth per model
	AggregateTPS         float64 `json:"aggregate_tps"`          // sum of effective decode TPS
	EstimatedTTFTMs      int64   `json:"estimated_ttft_ms"`      // best-case TTFT from lowest-cost warm provider
	TokenBudgetRemaining int64   `json:"token_budget_remaining"` // aggregate free budget across providers
	TokenBudgetTotal     int64   `json:"token_budget_total"`     // aggregate total budget
}

// providerCapSnap is a per-provider snapshot collected under the registry
// lock, then aggregated into ModelCapacity outside the lock.
type providerCapSnap struct {
	model                 string
	warm                  bool
	running               bool
	hasHeadroom           bool // pending < maxConcurrency
	effectiveTPS          float64
	prefillTPS            float64
	activeRequests        int // numRunning + numWaiting from backend slot, or pendingCount
	backlogTokens         float64
	activeTokenBudgetMax  int64
	activeTokenBudgetUsed int64
	queuedTokenBudget     int64
	// tokenBudgetKnownZero distinguishes an Engine V2 model whose positive KV
	// rate makes max==0 authoritative from a legacy model that omitted both.
	tokenBudgetKnownZero bool
	// pooledBudgetRemaining is the provider's whole-box pooled token budget
	// left after charging ALL models' coordinator-pending tokens — the same
	// pool the admission gate (pooledBudgetAdmits) enforces, so this public
	// capacity feed cannot advertise per-slot headroom dispatch would reject.
	// Reconstruction counts legacy shared headroom once and v0.7.5+ private
	// grants additively. -1 means no pooled budget report.
	pooledBudgetRemaining int64
}

// publiclyRoutableLocked reports whether a provider passes the public routing
// gates (status, privacy, trust, runtime, private-text support, challenge
// freshness). The caller must hold r.mu (read) and p.mu. It is shared by
// ModelCapacitySnapshot and FleetCapacitySnapshot so both count the same set of
// providers.
func (r *Registry) publiclyRoutableLocked(p *Provider, now time.Time) bool {
	// The public routing gate is exactly the liveness/trust/privacy core with no
	// owner relaxation — private-only machines never serve the public fleet.
	return r.providerLivenessGateLocked(p, r.MinTrustLevel, false, now)
}

// ModelCapacitySnapshot returns a capacity snapshot for every model served
// by at least one provider. Providers must pass the same routing gates as
// snapshotProviderIntoLockedEx (status, trust, runtime, privacy, challenge
// freshness, concurrency headroom) to be counted as routable.
func (r *Registry) ModelCapacitySnapshot() []ModelCapacity {
	now := time.Now()

	// Phase 1: collect per-provider snapshots under the lock.
	var snaps []providerCapSnap

	r.mu.RLock()
	for _, p := range r.providers {
		p.mu.Lock()

		// Apply the same gates as snapshotProviderIntoLockedEx. Private-only machines
		// never serve the public fleet, so they do not count toward public
		// model capacity.
		if !r.publiclyRoutableLocked(p, now) {
			p.mu.Unlock()
			continue
		}

		decodeTPS := resolvedDecodeTPS(p)
		prefillTPS := resolvedPrefillTPS(p)

		// Reconstruct the whole-box pooled budget and its all-models
		// coordinator-pending charges (token and, when every pending request
		// normalizes, byte) ONCE per provider — the SAME accumulation the
		// admission gate uses (fillSnapshotPendingAndPool). The per-model
		// remaining differs only by that model's KV rate in byte mode, so it is
		// finalized inside the model loop via pooledRemainingTokens, keeping this
		// feed's verdict identical to pooledBudgetAdmits' on a mixed-KV box (a
		// pool exhausted in BYTES by a small-KV burst must not surface token
		// headroom for a big-KV co-resident). Token units out; byte
		// normalization stays internal.
		var poolSnap routingSnapshot
		if p.BackendCapacity != nil {
			fillSnapshotPendingAndPool(&poolSnap, p, "")
		}

		// Enumerate every model this provider serves.
		for _, m := range p.Models {
			if !r.providerModelAllowedByCatalogLocked(p, m) {
				continue
			}
			// Use the SAME quality-concurrency-capped headroom the routing/preflight
			// path enforces, so the public capacity feed doesn't advertise a capped
			// box (e.g. Gemma at 2) as routable up to the flat fallback (24) and lure
			// upstream routers into sending requests this coordinator immediately 429s.
			hasHeadroom := r.hasConcurrencyHeadroomForModelCapResolvedLocked(p, m.ID)
			// Count only pending requests for this specific model, not the
			// total across all models. Using the total inflates
			// activeRequests for multi-model providers.
			modelPending := 0
			for _, pr := range p.pendingReqs {
				if pr.Model == m.ID {
					modelPending++
				}
			}

			// Per-model pooled remaining: byte-aware when the box is byte-
			// reconstructable, else token accounting — exactly pooledBudgetAdmits'
			// branch. Cold/absent slots have no rate (map miss ⇒ 0); on a byte-
			// reconstructable pool they are priced at the greater of the
			// conservative coordinator default and the box's max resident rate
			// (the same cold-rate resolver the gate uses), so this feed stays
			// equivalent to the gate on the cold path too. Inert for legacy boxes.
			pooledRemaining := pooledRemainingTokens(
				poolSnap.pooledTokenBudget,
				poolSnap.pendingMaxTokensAllModels,
				poolSnap.pendingMaxBytesAllModels,
				poolSnap.pendingBytesKnown,
				poolSnap.pooledTokenBudget.kvRateFor(m.ID),
			)

			snap := providerCapSnap{
				model:                 m.ID,
				hasHeadroom:           hasHeadroom,
				effectiveTPS:          decodeTPS,
				prefillTPS:            prefillTPS,
				activeRequests:        modelPending,
				pooledBudgetRemaining: pooledRemaining,
			}

			// Check backend capacity for this model's slot.
			if p.BackendCapacity != nil {
				for _, slot := range p.BackendCapacity.Slots {
					if slot.Model != m.ID {
						continue
					}
					snap.warm = slotStateModelLoaded(slot.State)
					snap.running = slot.State == "running"
					slotActive := int(slot.NumRunning) + int(slot.NumWaiting)
					if slotActive > snap.activeRequests {
						snap.activeRequests = slotActive
					}
					if slot.ObservedDecodeTPS > 0 {
						snap.effectiveTPS = slot.ObservedDecodeTPS
					}
					// Prefer the measured per-slot prefill EWMA over the ×12
					// fallback for the capacity TTFT estimate, mirroring the
					// routing path (resolvePrefillTPS). 0 = unreported.
					if slot.ObservedPrefillTPS > 0 {
						snap.prefillTPS = slot.ObservedPrefillTPS
					}
					snap.activeTokenBudgetMax = slot.ActiveTokenBudgetMax
					snap.activeTokenBudgetUsed = slot.ActiveTokenBudgetUsed
					snap.queuedTokenBudget = slot.QueuedTokenBudget
					snap.tokenBudgetKnownZero = knownZeroTokenBudget(slot.ActiveTokenBudgetMax, slot.KVBytesPerToken)
					snap.backlogTokens = float64(slot.MaxTokensPotential)
					break
				}
			} else {
				// Without backend capacity, warm if currently serving this model.
				snap.warm = p.CurrentModel == m.ID
			}

			snaps = append(snaps, snap)
		}
		p.mu.Unlock()
	}
	r.mu.RUnlock()

	// Phase 2: aggregate per-model outside the lock.
	type modelAgg struct {
		routable         int
		warm             int
		running          int
		cold             int
		activeRequests   int
		aggregateTPS     float64
		budgetRemaining  int64
		budgetTotal      int64
		bestWarmTTFTMs   int64 // -1 = not set
		bestColdTTFTMs   int64 // -1 = not set
		anyImmediateSlot bool  // at least one provider with headroom
	}
	agg := make(map[string]*modelAgg)
	for _, s := range snaps {
		a, ok := agg[s.model]
		if !ok {
			a = &modelAgg{bestWarmTTFTMs: -1, bestColdTTFTMs: -1}
			agg[s.model] = a
		}
		if s.warm {
			a.warm++
			if s.running {
				a.running++
			}
		} else {
			a.cold++
		}
		a.activeRequests += s.activeRequests
		a.aggregateTPS += s.effectiveTPS
		if s.activeTokenBudgetMax > 0 {
			headroom := s.activeTokenBudgetMax - s.activeTokenBudgetUsed - s.queuedTokenBudget
			if headroom < 0 {
				headroom = 0
			}
			// Per-slot headroom cannot exceed the provider's pooled remaining
			// after all-model pending charges. Without the clamp this surface can
			// advertise capacity pooledBudgetAdmits rejects.
			if s.pooledBudgetRemaining >= 0 && headroom > s.pooledBudgetRemaining {
				headroom = s.pooledBudgetRemaining
			}
			a.budgetRemaining += headroom
			a.budgetTotal += s.activeTokenBudgetMax
		}
		// Routable providers require both concurrency headroom AND token-budget
		// headroom. A provider with exhausted token budget should not make the
		// model appear immediately ready. An exhausted POOLED budget (0 — not
		// the -1 no-budget sentinel) counts as exhausted for every model on the
		// box, cold ones included: the admission gate charges those against the
		// whole-box pool too (freeMemoryAdmits' cold-slot pooled gate).
		hasBudgetHeadroom := !s.tokenBudgetKnownZero && (s.activeTokenBudgetMax <= 0 ||
			s.activeTokenBudgetUsed+s.queuedTokenBudget < s.activeTokenBudgetMax) &&
			s.pooledBudgetRemaining != 0
		if s.hasHeadroom && hasBudgetHeadroom {
			a.routable++
			a.anyImmediateSlot = true
		}

		// Estimate TTFT for this provider: prefill 500 tokens + backlog drain.
		const defaultPromptTokens = 500
		ttftMs := int64(0)
		if s.prefillTPS > 0 {
			ttftMs = int64(float64(defaultPromptTokens) / s.prefillTPS * 1000)
		}
		if s.effectiveTPS > 0 {
			ttftMs += int64(s.backlogTokens / s.effectiveTPS * 1000)
		}
		if s.warm {
			if a.bestWarmTTFTMs < 0 || ttftMs < a.bestWarmTTFTMs {
				a.bestWarmTTFTMs = ttftMs
			}
		} else {
			coldTTFT := ttftMs + 20_000 // 20s cold-start penalty
			if a.bestColdTTFTMs < 0 || coldTTFT < a.bestColdTTFTMs {
				a.bestColdTTFTMs = coldTTFT
			}
		}
	}

	// Phase 3: read queue sizes (separate lock, safe to call after releasing r.mu).
	queue := r.Queue()
	queueLimit := 0
	if queue != nil {
		queueLimit = queue.MaxSize()
	}

	result := make([]ModelCapacity, 0, len(agg))
	for model, a := range agg {
		queued := 0
		if queue != nil {
			queued = queue.QueueSize(model)
		}
		ready := a.routable > 0
		canAccept := ready && (queued < queueLimit || a.anyImmediateSlot)

		ttft := a.bestWarmTTFTMs
		if ttft < 0 {
			ttft = a.bestColdTTFTMs
		}
		if ttft < 0 {
			ttft = 0
		}

		result = append(result, ModelCapacity{
			ModelID:              model,
			Ready:                ready,
			CanAccept:            canAccept,
			RoutableProviders:    a.routable,
			WarmProviders:        a.warm,
			RunningProviders:     a.running,
			ColdProviders:        a.cold,
			ActiveRequests:       a.activeRequests,
			QueuedRequests:       queued,
			QueueLimit:           queueLimit,
			AggregateTPS:         a.aggregateTPS,
			EstimatedTTFTMs:      ttft,
			TokenBudgetRemaining: a.budgetRemaining,
			TokenBudgetTotal:     a.budgetTotal,
		})
	}
	return result
}
