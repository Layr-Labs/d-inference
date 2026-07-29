package registry

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/env"
	"github.com/eigeninference/d-inference/coordinator/protocol"
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
// ONE BOUNCED REQUEST PER CYCLE IS NOT ALWAYS CHEAP. Release condition (a) is
// phrased in terms of the pair's ADVERTISED budget, so when that budget is
// structurally inflated — as a paged slot's is, because its wire budget
// linearises an affine pool charge (v0.8.0; see budget_ceiling.go) — the very
// next heartbeat satisfies it and the cycle repeats every heartbeat forever.
// The clamp is therefore paired with a LEARNED EFFECTIVE CEILING
// (budget_ceiling.go) that outlives it: the clamp stops the bleeding for one
// heartbeat cycle, the ceiling remembers the commitment level that failed so
// the pair is deselected before dispatch instead of bounced again. The two are
// armed from the same entry point and keyed identically; the clamp is the
// tightest state of the same machine (headroom zero, release unproven).
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
	// budgetReported records whether the pair was REPORTING a token budget
	// when the clamp armed (sticky across re-arms). It is what keeps the clamp
	// holding through a budgetless window — a reconnected session has
	// BackendCapacity == nil until its first heartbeat, and without this flag
	// the snapshot's activeTokenBudgetMax == 0 would route the pair down the
	// legacy memory-admission path and shed the clamp exactly when it must
	// hold (a stable identity cannot drop a clamp by reconnecting). Pairs that
	// NEVER reported a budget (legacy providers) keep budgetReported == false
	// and keep their documented exemption: a single 503 cannot gate them.
	budgetReported bool
}

// recordBudgetClampLocked arms (or re-arms) the pair's budget clamp on a
// capacity-shaped rejection. A re-reject is fresh evidence: the clamp window
// restarts and the accept proof resets. budgetReported says whether the pair
// currently reports a token budget; it is STICKY across re-arms of a LIVE
// clamp (a re-reject during a reconnect's budgetless window must not downgrade
// the identity's demonstrated budget reporting) but is NOT inherited from a
// TTL-expired entry — see the in-body comment. Caller holds the r.mu write
// lock (called from RecordCapacityReject).
func (r *Registry) recordBudgetClampLocked(key capacityRejectKey, budgetReported bool, now time.Time) {
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
	// Sticky-or the demonstrated budget reporting from the PREVIOUS entry —
	// but only while that entry is still inside its TTL. The sticky-or exists
	// so a re-reject during a live clamp's budgetless reconnect window cannot
	// downgrade the identity's demonstrated reporting; a TTL-EXPIRED entry is a
	// clamp cycle that already failed open, and inheriting its budgetReported
	// would let a later benign budgetless reject (cold "not loaded" miss,
	// pre-heartbeat window) re-arm as stale-budget dishonesty and gate the pair
	// for another TTL — exactly what the budgetless-armed exemption forbids.
	if prev, ok := r.budgetClamps[key]; ok && now.Before(prev.clampedAt.Add(r.budgetClampCfg.TTL)) {
		budgetReported = budgetReported || prev.budgetReported
	}
	r.budgetClamps[key] = &budgetClampEntry{clampedAt: now, budgetReported: budgetReported}
}

// providerBudgetCommitmentLocked reads the pair's CURRENT advertised token
// budget (active_token_budget_max) and the tokens already committed against it
// (used + queued) from the live capacity snapshot. Both gray-box trackers read
// it: advertised > 0 is the clamp's arming-time budgetReported input, and
// committed is the base of the failing commitment the learned ceiling measures
// (budget_ceiling.go).
//
// A missing provider (the reject often races the disconnect that caused it) or
// a missing/budgetless slot reads zero — the sticky-or in
// recordBudgetClampLocked keeps an identity's demonstrated reporting from being
// downgraded by such a race, and a zero advertised budget makes the ceiling
// unlearnable rather than wrong.
//
// Thin wrapper over providerBudgetSnapshotLocked so the slot scan and the
// heartbeat stamp stay in ONE p.mu critical section: Heartbeat writes
// BackendCapacity and LastHeartbeat together, and a reader that took the lock
// twice could pair one heartbeat's stamp with another's budget. Caller holds
// r.mu (either mode); p.mu is taken inside (r.mu → p.mu lock order).
func (r *Registry) providerBudgetCommitmentLocked(providerID, modelID string) (advertised, committed int64) {
	_, advertised, committed = r.providerBudgetSnapshotLocked(providerID, modelID)
	return advertised, committed
}

// providerPendingTokensLocked sums the COORDINATOR's own view of the pair's
// in-flight token demand: pendingTokenBudget over every pending request for the
// model, the same aggregate snapshotProviderLocked stores as
// pendingMaxTokens and the admission gate charges as coordinatorExtra.
//
// The heartbeat-only commitment above lags by up to one heartbeat interval (5s
// by default), so during a burst it can read near-zero while the box is
// physically full. This is the term that closes that gap, and it is why the
// learned budget ceiling measures max(heartbeat, coordinator) rather than
// trusting the heartbeat alone. Caller holds the r.mu lock in either mode;
// p.mu is acquired here.
func (r *Registry) providerPendingTokensLocked(providerID, modelID string) int64 {
	p := r.providers[providerID]
	if p == nil {
		return 0
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	var pending int64
	for _, pr := range p.pendingReqs {
		if pr.Model == modelID {
			pending += int64(pendingTokenBudget(pr))
		}
	}
	return pending
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
// pair's live raw headroom from that snapshot (max - used - queued, unclamped)
// and budgetReported says whether the snapshot carries a budget for the pair
// at all (activeTokenBudgetMax > 0). The clamp holds while:
//   - the entry exists and is inside its TTL (fail-open bound), and
//   - release has not been proven: acceptedSince (condition b) AND a heartbeat
//     strictly after the clamp showing meaningful headroom (condition a).
//
// A budgetless snapshot (reconnect before the first heartbeat, or the model's
// slot missing from the current capacity report) can never satisfy condition
// (a), so a pair clamped while budget-reporting KEEPS holding through it —
// reconnecting must not shed the clamp onto the legacy memory-admission path
// (the stable fault key exists precisely so it can't). Pairs armed while
// budgetless (entry.budgetReported == false: legacy providers, cold "not
// loaded" misses, a first dispatch before the first heartbeat) NEVER hold —
// not even once a later heartbeat starts reporting a budget, since no dispatch
// could get through the clamp to produce the accept proof (the reject was
// never a stale-budget lie to begin with).
func (r *Registry) budgetClampActiveLocked(providerID, modelID string, heartbeatAt time.Time, rawBudgetRemaining int64, budgetReported bool, now time.Time) bool {
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
	if !e.budgetReported {
		// Armed while the pair reported NO token budget: a legacy provider, a
		// cold "model not loaded" miss, or a first dispatch before the first
		// capacity heartbeat. The clamp exists to override a STALE BUDGET, and a
		// budgetless reject is not a stale-budget lie — it must never gate.
		// Crucially, this must hold even after a LATER heartbeat starts
		// reporting a budget (the budgeted release branch below would otherwise
		// find acceptedSince=false and gate until TTL): the clamp would block
		// dispatch, so no accept could ever land to prove release, stranding the
		// warmed-up pair. A subsequent genuine reject while budget-reporting
		// re-arms with budgetReported=true (sticky-or in recordBudgetClampLocked)
		// and THAT gates.
		return false
	}
	if !budgetReported {
		// Armed while budget-reporting, but the current snapshot carries no
		// budget (reconnect before the first heartbeat, or the model's slot
		// missing from the live report): hold — reconnecting must not shed the
		// clamp onto the legacy memory-admission path (the stable fault key
		// exists precisely so it can't).
		return true
	}
	released := e.acceptedSince &&
		heartbeatAt.After(e.clampedAt) &&
		rawBudgetRemaining >= budgetClampReleaseMinHeadroomTokens
	return !released
}

// providerBudgetSnapshotLocked reads the pair's live budget snapshot: the
// heartbeat freshness anchor plus the same (advertised, committed) pair
// providerBudgetCommitmentLocked returns. The clamp's two derived inputs fall
// out of it — raw headroom is advertised − committed, and "the report carries
// a budget at all" is advertised > 0. A missing provider or a
// missing/budgetless slot reads zero. Caller holds r.mu (either mode); takes
// p.mu internally (r.mu → p.mu lock order).
func (r *Registry) providerBudgetSnapshotLocked(providerID, modelID string) (heartbeatAt time.Time, advertised, committed int64) {
	p := r.providers[providerID]
	if p == nil {
		return time.Time{}, 0, 0
	}
	// One critical section for all three: Heartbeat stamps LastHeartbeat and
	// swaps BackendCapacity together, so splitting the read could attribute one
	// heartbeat's freshness to another's budget — and the clamp's release proof
	// is precisely "a heartbeat strictly newer than the clamp showed headroom".
	p.mu.Lock()
	defer p.mu.Unlock()
	heartbeatAt = p.LastHeartbeat
	if p.BackendCapacity == nil {
		return heartbeatAt, 0, 0
	}
	for _, slot := range p.BackendCapacity.Slots {
		if slot.Model == modelID {
			return heartbeatAt, slot.ActiveTokenBudgetMax, slot.ActiveTokenBudgetUsed + slot.QueuedTokenBudget
		}
	}
	return heartbeatAt, 0, 0
}

// dropInactiveBudgetClampLocked deletes the pair's clamp entry when it can no
// longer gate admission, so the entry's lifecycle matches its effect:
//   - armed budgetless (entry.budgetReported == false: the exemption means it
//     NEVER gates, so keeping it only costs the accept fast path);
//   - TTL lapsed (fail-open — a re-reject re-arms fresh anyway);
//   - fully released (accept proof AND a strictly-fresher heartbeat with
//     meaningful headroom, evaluated against the provider's live snapshot).
//
// Deleting on release matters twice over: a lingering released entry (a) keeps
// pulling every subsequent RecordCapacityAccept for the pair onto the r.mu
// write lock (the fast-path gate keys on map presence), and (b) revives as a
// block on the identity's next reconnect — the budgetless pre-heartbeat hold
// branch treats an unreleased-looking entry as an active clamp, re-blocking a
// pair that already proved recovery. A deleted entry re-arms from scratch on
// the next reject, with budgetReported re-read at arm time. Called from the
// accept path (RecordCapacityAcceptOutcome); the heartbeat release sweep uses
// the snapshot variant below. Caller holds the r.mu WRITE lock.
func (r *Registry) dropInactiveBudgetClampLocked(providerID, modelID string, now time.Time) {
	heartbeatAt, advertised, committed := r.providerBudgetSnapshotLocked(providerID, modelID)
	r.dropInactiveBudgetClampSnapshotLocked(providerID, modelID, heartbeatAt, advertised-committed, advertised > 0, now)
}

// dropInactiveBudgetClampSnapshotLocked is dropInactiveBudgetClampLocked with
// the budget snapshot supplied by the caller instead of re-read from
// r.providers. The heartbeat release sweep passes the just-delivered
// heartbeat's OWN stamped time and slot values, so the release proof cannot be
// voided by a disconnect racing in between the heartbeat stamping the provider
// and the sweep running — a re-read would find no provider, skip the delete,
// and let the released entry re-block the identity's next reconnect. Caller
// holds the r.mu WRITE lock.
func (r *Registry) dropInactiveBudgetClampSnapshotLocked(providerID, modelID string, heartbeatAt time.Time, rawRemaining int64, budgetReported bool, now time.Time) {
	key := capacityRejectKey{ProviderID: r.faultKeyLocked(providerID), ModelID: modelID}
	e, ok := r.budgetClamps[key]
	if !ok {
		return
	}
	if !e.budgetReported || !now.Before(e.clampedAt.Add(r.budgetClampCfg.TTL)) {
		delete(r.budgetClamps, key)
		return
	}
	if !e.acceptedSince {
		return
	}
	if budgetReported &&
		heartbeatAt.After(e.clampedAt) &&
		rawRemaining >= budgetClampReleaseMinHeadroomTokens {
		delete(r.budgetClamps, key)
	}
}

// releaseBudgetClampsOnHeartbeat drops any clamp entries for the provider's
// heartbeat-reported models that the just-stamped capacity snapshot proves
// inactive (released / TTL-expired / budgetless-armed). Called from Heartbeat
// AFTER BackendCapacity and LastHeartbeat are written, so the
// accept-then-heartbeat release order cleans up even when the pair gets no
// further traffic — otherwise the released entry would linger and re-block the
// identity's next reconnect before its first heartbeat.
//
// heartbeatAt and capacity are the heartbeat's OWN stamped time and (clamped)
// report, evaluated directly rather than re-read from r.providers, so a
// disconnect racing in after the heartbeat cannot void this heartbeat's
// release proof. The common case (no clamp state for the provider) is a
// read-locked probe with one map lookup per reported slot; the write lock is
// taken only when an entry actually exists.
func (r *Registry) releaseBudgetClampsOnHeartbeat(providerID string, heartbeatAt time.Time, capacity *protocol.BackendCapacity) {
	if !r.budgetClampCfg.Enabled || capacity == nil || len(capacity.Slots) == 0 {
		return
	}
	r.mu.RLock()
	faultKey := r.faultKeyLocked(providerID)
	var found []protocol.BackendSlotCapacity
	for _, slot := range capacity.Slots {
		if _, ok := r.budgetClamps[capacityRejectKey{ProviderID: faultKey, ModelID: slot.Model}]; ok {
			found = append(found, slot)
		}
	}
	r.mu.RUnlock()
	if len(found) == 0 {
		return
	}
	r.mu.Lock()
	now := time.Now()
	for _, slot := range found {
		rawRemaining := slot.ActiveTokenBudgetMax - slot.ActiveTokenBudgetUsed - slot.QueuedTokenBudget
		r.dropInactiveBudgetClampSnapshotLocked(providerID, slot.Model, heartbeatAt, rawRemaining, slot.ActiveTokenBudgetMax > 0, now)
	}
	r.mu.Unlock()
}

// BudgetClampActive reports whether the (provider, model) pair's token budget
// is currently clamped for admission. Exposed for tests and observability; the
// routing hot path uses budgetClampActiveLocked under the already-held r.mu.
func (r *Registry) BudgetClampActive(providerID, modelID string) bool {
	r.mu.RLock()
	defer r.mu.RUnlock()
	if r.providers[providerID] == nil {
		return false
	}
	heartbeatAt, advertised, committed := r.providerBudgetSnapshotLocked(providerID, modelID)
	return r.budgetClampActiveLocked(providerID, modelID, heartbeatAt, advertised-committed, advertised > 0, time.Now())
}
