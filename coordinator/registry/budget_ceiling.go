package registry

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/env"
)

// Learned effective token-budget ceiling — the DURABLE half of the gray-box
// fix, sitting behind the one-shot clamp in budget_clamp.go.
//
// # Why the clamp alone is a treadmill
//
// The clamp is a boolean: one capacity-503 zeroes the pair's live headroom,
// and release condition (a) — raw max − used − queued ≥
// budgetClampReleaseMinHeadroomTokens — is satisfied by the very next
// heartbeat WHENEVER THE ADVERTISED BUDGET IS STRUCTURALLY INFLATED. The pair
// is then re-selected at the same commitment level, rejected again, clamped
// again. One bounced request per heartbeat, indefinitely.
//
// v0.8.0 made that inflation structural rather than incidental. A paged slot
// advertises poolBytes / kvBytesPerToken, where kvBytesPerToken is the
// MARGINAL long-context rate over full-attention layers only. The paged pool's
// real charge is AFFINE, not linear: PagedKVPool.pageDemand charges each
// sliding-window layer a fixed ring of pages regardless of sequence length
// (gemma-4: ~303 MiB per in-flight sequence, ≈15.5k tokens' worth at its
// 20,480 B/token marginal rate) PLUS the marginal per-token cost. The wire
// budget therefore over-states concurrent capacity by ~1.6× at batch 8: the
// coordinator computes that 9 requests fit a 6 GiB pool that physically holds
// 6, and requests 7–9 come back token_budget_exhausted. The heartbeat is not
// stale — it is honestly reporting a number whose model of the pool is wrong.
// No release condition phrased in terms of that number can ever break the
// cycle.
//
// # What this learns instead
//
// The intercept is unknown to the coordinator and differs per box, per model
// and per batch shape, so this does not model it. It MEASURES it. On a
// capacity reject the coordinator knows the commitment that failed:
//
//	S = max(used + queued, pendingForModel − requestTokens) + requestTokens
//
// in the same units the admission gate charges. The max matters: the heartbeat
// half (used+queued) lags a burst by up to one heartbeat interval, and the
// coordinator's own pending half is exactly the coordinatorExtra term
// freeMemoryAdmits adds for that reason. Learning off the heartbeat alone would
// read used≈0 mid-burst and latch an order of magnitude too tight. Latching
//
//	effectiveMax = min(advertised, S − budgetCeilingMarginTokens)
//
// is the weakest statement consistent with the evidence: "this pair could not
// hold S". The next request at the same commitment is then DESELECTED BEFORE
// DISPATCH — it takes the existing queue-before-shed spill and is served when
// a slot frees — instead of being dispatched, rejected, retried three times
// and 429'd. As the box drains, used+queued falls and the pair becomes
// selectable again on its own, which is exactly the behaviour a full slot
// should have. No modelling constant, no wire change, self-calibrating per box
// and per model.
//
// # Strictly tighter, and it cannot over-admit
//
// The ceiling is applied as min(advertised, learned) at every read, so the
// admission gate never believes a LARGER budget than the heartbeat advertises.
// It composes with — it does not replace — the clamp: while a clamp holds, the
// pair is FULL exactly as before (the boolean is the ceiling at its tightest);
// once the clamp releases, the learned ceiling keeps the pair off the
// commitment level that just failed. Every state of this machine is at least
// as tight as the pre-change behaviour at the same instant.
//
// # Recovery, and why it cannot strand a slot
//
//   - Draining: a ceiling only deselects while used+queued+request exceeds it.
//     A busy box that finishes work is re-selected with no state change at all.
//   - Widening: every budgetCeilingWidenAccepts accepts for the pair widen the
//     ceiling by 1/budgetCeilingWidenDivisor of its current value; once it
//     reaches the advertised budget the entry is deleted and the pair is back
//     on pure heartbeat semantics. Accepts are the only provider-side proof
//     that more fits than we learned. This route is only open when SOME request
//     size still fits under the ceiling: it is fast for a pair whose traffic
//     straddles the ceiling (~40 short requests to climb 1k→90k) and closed
//     for a pair whose traffic is uniformly larger than it.
//   - TTL: an entry never outlives latchedAt+TTL. This is the fail-open bound
//     for exactly the case widening cannot reach — a ceiling low enough to
//     deselect the pair for every request size the model actually receives, so
//     no accept can land. Such a pair is dark for the remainder of the TTL and
//     nothing but the TTL recovers it, which is why non-tightening rejects must
//     not refresh the anchor (see recordBudgetCeilingLocked) and why the
//     latch/heal transitions are logged.
//
// # Scope
//
// Learning requires (a) a reject the api layer classified as indicting the
// PROVIDER (the same armClamp gate the clamp uses — a request-deterministic
// oversized prompt or a cold "not loaded" miss says nothing about budget
// arithmetic), (b) a pair that actually advertises a token budget, and (c) a
// known request size. Without a request size the commitment that failed is
// unknown, so RecordCapacityReject (the unsized entry point) records a strike
// and a clamp but learns nothing.
//
// Keyed by the STABLE fault identity like every sibling breaker, migrated on
// identity rebind (migrateFaultStateLocked) and deliberately NOT cleared by
// Disconnect — a reconnect must not shed a learned ceiling any more than it
// sheds a cooldown. Map bounded by the same opportunistic >1024 sweep. All
// state guarded by r.mu; routing-path reads happen under r.mu in either mode.
const (
	// envBudgetCeiling is the kill switch. Default ON; set to false/0 to
	// restore pure clamp-only behaviour (advertised budget believed in full
	// the moment the clamp releases).
	envBudgetCeiling = "EIGENINFERENCE_BUDGET_CEILING"
	// envBudgetCeilingTTLSecs caps how long a learned ceiling survives its
	// last latch — the fail-open bound. Default 600s.
	envBudgetCeilingTTLSecs = "EIGENINFERENCE_BUDGET_CEILING_TTL_SECONDS"
)

const (
	// defaultBudgetCeilingTTL deliberately outlives defaultBudgetClampTTL: the
	// clamp's job is to stop the bleeding for one heartbeat cycle, this one's
	// is to survive the heartbeat that would otherwise re-inflate the budget.
	// A TTL at or below the clamp's would reproduce the treadmill one cycle
	// later.
	defaultBudgetCeilingTTL = 10 * time.Minute
	// budgetCeilingMarginTokens is subtracted from the observed failing
	// commitment so the SAME request at the SAME commitment is deselected
	// rather than landing exactly on the boundary. 1024 is the provider's own
	// minimum serving budget (BatchScheduler+Telemetry floors tokenBudgetMax
	// there), reused so the hysteresis is one provider-minimum wide instead of
	// an invented number.
	budgetCeilingMarginTokens = budgetClampReleaseMinHeadroomTokens
	// budgetCeilingFloorTokens keeps a learned ceiling positive. Below the
	// provider's own minimum serving budget the pair could not serve anything
	// at all, and a zero/negative ceiling would be a permanent clamp wearing a
	// different name.
	budgetCeilingFloorTokens = budgetClampReleaseMinHeadroomTokens
	// budgetCeilingWidenAccepts is how many accepts for the pair it takes to
	// widen the ceiling one step. Accepts are cheap on a serving box (first
	// content chunk and clean completion both count), so recovery from an
	// over-tight learn is seconds, not minutes.
	budgetCeilingWidenAccepts = 4
	// budgetCeilingWidenDivisor sets the step size: each widen adds
	// ceiling/budgetCeilingWidenDivisor, i.e. +25%. Geometric on purpose — the
	// distance back to the advertised budget is multiplicative (the paged
	// over-statement is a ratio), so a fixed token step would take
	// unboundedly long from a heavily derated ceiling.
	budgetCeilingWidenDivisor = 4
)

// budgetCeilingConfig carries the env-tunable ceiling parameters, read once at
// Registry construction (coordinator restart applies changes), mirroring
// budgetClampConfig.
type budgetCeilingConfig struct {
	// Enabled is the kill switch (EIGENINFERENCE_BUDGET_CEILING, default true).
	Enabled bool
	// TTL is the fail-open bound: a ceiling never outlives latchedAt+TTL.
	TTL time.Duration
}

// loadBudgetCeilingConfig reads the EIGENINFERENCE_BUDGET_CEILING* env
// tunables, clamping nonsensical values back to the defaults.
func loadBudgetCeilingConfig() budgetCeilingConfig {
	cfg := budgetCeilingConfig{
		Enabled: env.EnvBool(envBudgetCeiling, true),
		TTL:     time.Duration(env.EnvInt(envBudgetCeilingTTLSecs, int(defaultBudgetCeilingTTL/time.Second))) * time.Second,
	}
	if cfg.TTL <= 0 {
		cfg.TTL = defaultBudgetCeilingTTL
	}
	return cfg
}

// budgetCeilingEntry is one pair's learned ceiling. Written ONLY under the
// r.mu write lock (latched in recordCapacityReject, widened in
// RecordCapacityAcceptOutcome); routing paths read it under r.mu in either
// mode.
type budgetCeilingEntry struct {
	// tokens is the learned effective token-budget max. Readers apply
	// min(advertised, tokens), so this is a ceiling ON TOP of the heartbeat,
	// never a substitute that could exceed it.
	tokens int64
	// latchedAt is when the last TIGHTENING reject landed — the TTL anchor.
	// Widening does not move it: widening is the healthy path, the TTL is the
	// fail-open bound on the unhealthy one.
	latchedAt time.Time
	// acceptsSince counts accepts since the last latch or widen step.
	acceptsSince int
}

// recordBudgetCeilingLocked latches (or tightens) the pair's learned ceiling
// from a capacity reject observed at commitment observedCommitment, against
// the budget the pair was advertising at the time. Caller holds the r.mu WRITE
// lock (called from recordCapacityReject).
//
// Only TIGHTENING rejects (re)latch. A reject whose implied ceiling is at or
// above the advertised budget teaches nothing — the advertised number was
// already the binding term, which is the ordinary "the box is genuinely full"
// case the queue path owns — and refreshing the TTL off it would extend a
// derating window on evidence that did not produce it.
func (r *Registry) recordBudgetCeilingLocked(key capacityRejectKey, observedCommitment, alreadyCommitted, advertised int64, now time.Time) {
	if !r.budgetCeilingCfg.Enabled || observedCommitment <= 0 || advertised <= 0 {
		return
	}
	learned := observedCommitment - budgetCeilingMarginTokens
	// Never learn a ceiling BELOW what the pair was already holding without
	// this request. The margin exists to push the next identical request off
	// the boundary, but for a request smaller than the margin it would
	// otherwise push the ceiling under the live commitment — a number the
	// pair's own accounting contradicts, and one low enough to deselect the
	// pair for every request size (which produces no accepts, so only the TTL
	// could recover it). The gate still rejects the request that failed: any
	// positive demand on top of a ceiling equal to the base does not fit.
	if learned < alreadyCommitted {
		learned = alreadyCommitted
	}
	if learned < budgetCeilingFloorTokens {
		learned = budgetCeilingFloorTokens
	}
	// A ceiling at or above the commitment that just failed changes no
	// decision — the identical request at the identical commitment is
	// re-admitted — and a ceiling at or above the advertised budget is
	// dominated by the heartbeat. Either way the entry would gate nothing
	// while still burning a TTL and the accept bookkeeping, so do not create
	// one. (The first case is reachable only when the floor binds, i.e. the
	// whole failing commitment was under one provider-minimum budget.)
	if learned >= observedCommitment || learned >= advertised {
		return
	}
	// Opportunistic sweep (mirrors the sibling clamp/cooldown maps):
	// session-keyed entries for churned identities are never re-keyed, so
	// bound the map by dropping expired ceilings once it grows.
	if len(r.budgetCeilings) > 1024 {
		for k, e := range r.budgetCeilings {
			if !now.Before(e.latchedAt.Add(r.budgetCeilingCfg.TTL)) {
				delete(r.budgetCeilings, k)
			}
		}
	}
	// Ratchet: a live entry that already knows a ceiling at least this tight
	// keeps it, TTL ANCHOR INCLUDED. A reject cannot widen — only accepts can,
	// and only through the widen path below — so without the token half a
	// reject arriving at high commitment (a busy box) would undo what a reject
	// at low commitment (the same box, gray) taught. And without the latchedAt
	// half, a non-tightening reject would refresh the TTL off evidence that
	// did not produce the ceiling, extending the derating window for free. The
	// reject does reset progress toward widening: it is direct evidence
	// against the accepts that had accumulated.
	if prev, ok := r.budgetCeilings[key]; ok &&
		now.Before(prev.latchedAt.Add(r.budgetCeilingCfg.TTL)) &&
		prev.tokens <= learned {
		prev.acceptsSince = 0
		return
	}
	r.budgetCeilings[key] = &budgetCeilingEntry{tokens: learned, latchedAt: now}
	if r.logger != nil {
		// The only window into this mechanism during an incident: which pair,
		// how far below its own advertised budget, and off what commitment.
		r.logger.Warn("budget ceiling latched",
			"provider_id", key.ProviderID,
			"model", key.ModelID,
			"learned_tokens", learned,
			"advertised_tokens", advertised,
			"failing_commitment_tokens", observedCommitment,
			"latched_pairs", len(r.budgetCeilings))
	}
}

// noteBudgetCeilingAcceptLocked records one accept for the pair and widens the
// learned ceiling once budgetCeilingWidenAccepts have landed since the last
// latch or widen. A ceiling that has caught up with (or passed) the pair's
// currently advertised budget is DELETED: the pair is healed and belongs back
// on pure heartbeat semantics, and a lingering entry would keep pulling every
// later accept onto the write lock. An expired entry is deleted for the same
// reason. Caller holds the r.mu WRITE lock (called from
// RecordCapacityAcceptOutcome).
func (r *Registry) noteBudgetCeilingAcceptLocked(providerID, modelID string, key capacityRejectKey, now time.Time) {
	e, ok := r.budgetCeilings[key]
	if !ok {
		return
	}
	if !now.Before(e.latchedAt.Add(r.budgetCeilingCfg.TTL)) {
		delete(r.budgetCeilings, key)
		return
	}
	e.acceptsSince++
	if e.acceptsSince < budgetCeilingWidenAccepts {
		return
	}
	e.acceptsSince = 0
	step := e.tokens / budgetCeilingWidenDivisor
	if step < budgetCeilingMarginTokens {
		// Guarantee progress: a ceiling small enough that the geometric step
		// rounds to less than the margin would otherwise widen by nothing and
		// wait out the TTL.
		step = budgetCeilingMarginTokens
	}
	e.tokens += step
	// Healed? Compare against what the pair advertises RIGHT NOW, not against
	// the value at latch time — the advertised budget moves with residency and
	// co-tenancy, and the entry only exists to hold the pair below it.
	advertised, _ := r.providerBudgetCommitmentLocked(providerID, modelID)
	if advertised > 0 && e.tokens >= advertised {
		delete(r.budgetCeilings, key)
		if r.logger != nil {
			r.logger.Info("budget ceiling healed",
				"provider_id", key.ProviderID,
				"model", key.ModelID,
				"advertised_tokens", advertised,
				"latched_pairs", len(r.budgetCeilings))
		}
	}
}

// budgetCeilingLocked returns the token-budget max admission must use for the
// pair: min(advertised, learned ceiling), or advertised when nothing is
// learned / the entry expired / the tracker is disabled. READ-ONLY (no lazy
// delete) — routing paths call it under r.mu held in either mode, mirroring
// budgetClampActiveLocked.
func (r *Registry) budgetCeilingLocked(providerID, modelID string, advertised int64, now time.Time) int64 {
	if !r.budgetCeilingCfg.Enabled || advertised <= 0 {
		return advertised
	}
	e, ok := r.budgetCeilings[capacityRejectKey{ProviderID: r.faultKeyLocked(providerID), ModelID: modelID}]
	if !ok || !now.Before(e.latchedAt.Add(r.budgetCeilingCfg.TTL)) {
		return advertised
	}
	if e.tokens < advertised {
		return e.tokens
	}
	return advertised
}

// BudgetCeiling reports the pair's learned effective token-budget ceiling and
// whether one is currently latched. Exposed for tests and observability; the
// routing hot path uses budgetCeilingLocked under the already-held r.mu.
func (r *Registry) BudgetCeiling(providerID, modelID string) (tokens int64, latched bool) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	if !r.budgetCeilingCfg.Enabled {
		return 0, false
	}
	e, ok := r.budgetCeilings[capacityRejectKey{ProviderID: r.faultKeyLocked(providerID), ModelID: modelID}]
	if !ok || !time.Now().Before(e.latchedAt.Add(r.budgetCeilingCfg.TTL)) {
		return 0, false
	}
	return e.tokens, true
}
