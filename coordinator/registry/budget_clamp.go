package registry

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/env"
)

// Budget clamp on capacity-shaped provider 503s — the fast, surgical half of
// the "gray box" fix.
//
// Prod gap (2026-07, gemma-4-26b-qat-4bit on mixed boxes co-resident with
// gpt-oss-20b, DEDICATED_MODELS off): 11,581 provider 503s of the
// capacity/token-budget shape in 6h from boxes whose heartbeats looked nearly
// idle — active_token_budget_used ~72k of active_token_budget_max ~5.2M
// (~1.4%) at ADMIT time. The heartbeat budget is stale-OPTIMISTIC: the
// provider's live KV gate shrinks with real MLX memory pressure between
// heartbeats and accounts for co-resident engines, so it rejects requests the
// last-reported budget says fit. Because the boxes still served ~60% of
// dispatches, every existing breaker was blind by design: the pair
// capacity-cooldown (capacity_cooldown.go) and the node capacity streak
// (health_ejection.go) both require ZERO interleaved accepts, and each accept
// reset them. The scheduler kept believing the stale budget and kept
// dispatching.
//
// THE CLAMP: the moment the api layer classifies a provider error as a
// capacity/token-budget rejection for a (provider, model) pair
// (RecordCapacityReject — the same entry point that feeds the cooldown), the
// registry stops believing the pair's heartbeat budget: admission treats the
// slot as FULL (freeMemoryAdmits' budget branch rejects, providerBudgetFits
// reports zero live headroom), so the pair immediately stops attracting new
// dispatches. One 503 is enough — the provider itself just told us its live
// gate is rejecting, which is strictly fresher evidence than any heartbeat.
//
// RELEASE requires provider-side proof, not just the next optimistic
// heartbeat. BOTH must hold (so release lands at whichever comes later):
//
//	(a) a heartbeat DELIVERED STRICTLY AFTER the clamp whose budget snapshot
//	    shows meaningful headroom (raw max - used - queued >=
//	    budgetClampReleaseMinHeadroomTokens) — the provider re-stated its
//	    budget knowing about the rejection-time pressure; and
//	(b) an accept (RecordCapacityAccept: first content chunk or clean
//	    completion) landed for the pair AFTER the clamp — the pair proved it
//	    is actually serving work. In-flight requests dispatched before the
//	    clamp keep producing accepts, so a healthy-but-momentarily-full box
//	    releases within roughly one heartbeat interval.
//
// FAIL OPEN: a clamp expires after budgetClampTTL (default 5 min) no matter
// what, so a missed release path (e.g. a pair that gets zero traffic and
// therefore zero accepts) can never strand a slot forever. A re-reject after
// release or expiry simply re-arms the clamp — a persistent gray box costs
// ~one bounced request per release cycle, and the capacity-rate penalty
// (capacity_rate.go) keeps it deprioritized in between.
//
// SCOPE: the clamp only gates slots that REPORT a token budget
// (active_token_budget_max > 0) — it exists to override a stale budget, and
// its release condition is budget-defined. Legacy providers without budget
// telemetry keep the existing protections (pair cooldown at threshold 5,
// node-level streaks) and are never clamped, so a single 503 cannot gate them.
//
// Keyed by the STABLE fault identity (faultKeyLocked: serial → SE-key →
// account → session fallback) like every sibling breaker, so a reconnect
// cannot shed the clamp; migrated on identity rebind (migrateFaultStateLocked)
// and deliberately NOT cleared by Disconnect. Map is bounded by the same
// opportunistic >1024 sweep as the sibling cooldown maps. All state is guarded
// by r.mu; the routing-path reads happen under r.mu held in either mode.
const (
	// envBudgetClamp is the kill switch. Default ON; set to false/0 to restore
	// pre-clamp behavior (stale-heartbeat admission).
	envBudgetClamp = "EIGENINFERENCE_BUDGET_CLAMP"
	// envBudgetClampTTLSecs caps how long a clamp can hold without release —
	// the fail-open bound. Default 300s.
	envBudgetClampTTLSecs = "EIGENINFERENCE_BUDGET_CLAMP_TTL_SECONDS"
)

const (
	defaultBudgetClampTTL = 5 * time.Minute
	// budgetClampReleaseMinHeadroomTokens is the "meaningful headroom" floor a
	// post-clamp heartbeat must show before release condition (a) holds. 1024
	// mirrors the provider's own token-budget floor (BatchScheduler+Telemetry:
	// tokenBudgetMax floored at 1024): a pressured box reports max ≈ used +
	// (little), so requiring at least the provider's own minimum serving
	// budget of free room filters heartbeats that merely restate the pressure.
	budgetClampReleaseMinHeadroomTokens = 1024
)

// budgetClampConfig carries the env-tunable clamp parameters, read once at
// Registry construction (coordinator restart applies changes), mirroring
// capacityCooldownConfig.
type budgetClampConfig struct {
	// Enabled is the kill switch (EIGENINFERENCE_BUDGET_CLAMP, default true).
	Enabled bool
	// TTL is the fail-open bound: a clamp never outlives clampedAt+TTL.
	TTL time.Duration
}

// loadBudgetClampConfig reads the EIGENINFERENCE_BUDGET_CLAMP* env tunables,
// clamping nonsensical values back to the defaults.
func loadBudgetClampConfig() budgetClampConfig {
	cfg := budgetClampConfig{
		Enabled: env.EnvBool(envBudgetClamp, true),
		TTL:     time.Duration(env.EnvInt(envBudgetClampTTLSecs, int(defaultBudgetClampTTL/time.Second))) * time.Second,
	}
	if cfg.TTL <= 0 {
		cfg.TTL = defaultBudgetClampTTL
	}
	return cfg
}

// budgetClampEntry is one pair's active (or released/expired-awaiting-sweep)
// clamp. Written ONLY under the r.mu write lock (armed/re-armed in
// RecordCapacityReject, accept flag in RecordCapacityAccept); routing paths
// read it under r.mu in either mode.
type budgetClampEntry struct {
	// clampedAt is when the capacity-503 landed — the freshness reference for
	// release condition (a) and the TTL anchor.
	clampedAt time.Time
	// acceptedSince records release condition (b): an accept landed for the
	// pair after clampedAt.
	acceptedSince bool
}

// recordBudgetClampLocked arms (or re-arms) the pair's budget clamp on a
// capacity-shaped rejection. A re-reject is fresh evidence: the clamp window
// restarts and the accept proof resets. Caller holds the r.mu write lock
// (called from RecordCapacityReject).
func (r *Registry) recordBudgetClampLocked(key capacityRejectKey, now time.Time) {
	if !r.budgetClampCfg.Enabled {
		return
	}
	// Opportunistic sweep (mirrors the sibling cooldown maps): session-keyed
	// entries for churned identities are never re-keyed, so bound the map by
	// dropping TTL-expired clamps once it grows.
	if len(r.budgetClamps) > 1024 {
		for k, e := range r.budgetClamps {
			if !now.Before(e.clampedAt.Add(r.budgetClampCfg.TTL)) {
				delete(r.budgetClamps, k)
			}
		}
	}
	r.budgetClamps[key] = &budgetClampEntry{clampedAt: now}
}

// noteBudgetClampAcceptLocked records release condition (b): the pair accepted
// work after the clamp. The entry is kept (not deleted) — release also needs a
// strictly-fresher heartbeat with meaningful headroom, which the routing-path
// read evaluates against the provider's live budget fields. Caller holds the
// r.mu write lock (called from RecordCapacityAccept).
func (r *Registry) noteBudgetClampAcceptLocked(key capacityRejectKey) {
	if e, ok := r.budgetClamps[key]; ok {
		e.acceptedSince = true
	}
}

// budgetClampActiveLocked reports whether admission must treat the pair's slot
// as FULL right now. READ-ONLY (no lazy delete) — routing paths call it under
// r.mu held in either mode, mirroring capacityCooldownActiveLocked.
//
// heartbeatAt is when the provider's CURRENT BackendCapacity was delivered
// (p.LastHeartbeat — Heartbeat overwrites BackendCapacity and stamps
// LastHeartbeat in the same critical section). rawBudgetRemaining is the
// pair's live raw headroom from that snapshot (max - used - queued, unclamped).
// The clamp holds while:
//   - the entry exists and is inside its TTL (fail-open bound), and
//   - release has not been proven: acceptedSince (condition b) AND a heartbeat
//     strictly after the clamp showing meaningful headroom (condition a).
func (r *Registry) budgetClampActiveLocked(providerID, modelID string, heartbeatAt time.Time, rawBudgetRemaining int64, now time.Time) bool {
	if !r.budgetClampCfg.Enabled {
		return false
	}
	e, ok := r.budgetClamps[capacityRejectKey{ProviderID: r.faultKeyLocked(providerID), ModelID: modelID}]
	if !ok {
		return false
	}
	if !now.Before(e.clampedAt.Add(r.budgetClampCfg.TTL)) {
		return false // TTL lapsed: fail open (a re-reject re-arms)
	}
	released := e.acceptedSince &&
		heartbeatAt.After(e.clampedAt) &&
		rawBudgetRemaining >= budgetClampReleaseMinHeadroomTokens
	return !released
}

// BudgetClampActive reports whether the (provider, model) pair's token budget
// is currently clamped for admission. Exposed for tests and observability; the
// routing hot path uses budgetClampActiveLocked under the already-held r.mu.
func (r *Registry) BudgetClampActive(providerID, modelID string) bool {
	r.mu.RLock()
	defer r.mu.RUnlock()
	p := r.providers[providerID]
	if p == nil {
		return false
	}
	p.mu.Lock()
	heartbeatAt := p.LastHeartbeat
	var rawRemaining int64
	if p.BackendCapacity != nil {
		for _, slot := range p.BackendCapacity.Slots {
			if slot.Model == modelID {
				rawRemaining = slot.ActiveTokenBudgetMax - slot.ActiveTokenBudgetUsed - slot.QueuedTokenBudget
				break
			}
		}
	}
	p.mu.Unlock()
	return r.budgetClampActiveLocked(providerID, modelID, heartbeatAt, rawRemaining, time.Now())
}
