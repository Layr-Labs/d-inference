package identitygate

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/env"
)

// Env tunables — read ONCE at Registry construction (coordinator restart
// applies changes). All values have safe defaults; setting the threshold to 0
// disables the cooldown entirely (kill switch).
const (
	envCapacityCooldownThreshold  = "EIGENINFERENCE_CAPACITY_COOLDOWN_THRESHOLD"
	envCapacityCooldownWindowSecs = "EIGENINFERENCE_CAPACITY_COOLDOWN_WINDOW_SECONDS"
	envCapacityCooldownTTLSecs    = "EIGENINFERENCE_CAPACITY_COOLDOWN_TTL_SECONDS"
	envCapacityCooldownMaxTTLSecs = "EIGENINFERENCE_CAPACITY_COOLDOWN_MAX_TTL_SECONDS"
)

const (
	DefaultCapacityCooldownThreshold = 5
	defaultCapacityCooldownWindow    = 60 * time.Second
	defaultCapacityCooldownTTL       = 120 * time.Second
	defaultCapacityCooldownMaxTTL    = 10 * time.Minute
)

// capacityProbeOutcomeWindow is how long a claimed post-expiry probe keeps the
// gate closed to everyone else while its outcome is pending. A reject outcome
// lands within seconds (capacity rejects are immediate); an accept usually
// does too, but on the accept-then-reload path first content can take much
// longer, so this window is deliberately short — it is a LIVENESS bound, not
// the accept deadline: if it lapses before the outcome lands, the next
// reservation may claim a fresh probe (one extra probe per window during a
// genuinely slow load — the box is accepting, so that is acceptable). Its real
// job is that a probe request which DIED before any terminal reached the
// breaker hooks can never wedge the pair closed forever.
const capacityProbeOutcomeWindow = 30 * time.Second

// capacityCooldownEntry is one pair's active (or expired-awaiting-probe)
// cooldown. Fields are written and read ONLY under the identity's gate.mu
// (arm/re-arm in RecordCapacityReject, probe claim in tryClaimCapacityProbe).
type capacityCooldownEntry struct {
	// expiry is when the quarantine TTL lapses and the pair becomes eligible
	// for a single half-open probe.
	expiry time.Time
	// probeAt is when a post-expiry probe was claimed (zero = unclaimed).
	// While the claim is fresh (now < probeAt+capacityProbeOutcomeWindow) the
	// gate stays closed to everyone but the claimed probe.
	probeAt time.Time
}

// CapacityCooldownConfig carries the env-tunable cooldown parameters.
type CapacityCooldownConfig struct {
	// Threshold is how many capacity rejects inside Window — with ZERO accepts
	// interleaved — trip the cooldown. <= 0 disables the breaker (kill switch).
	Threshold int
	// Window is the sliding window over which reject strikes count.
	Window time.Duration
	// BaseTTL is the first cooldown duration. Each re-trip without an
	// intervening accept doubles it (half-open re-arm), capped at MaxTTL.
	BaseTTL time.Duration
	// MaxTTL caps the exponential backoff.
	MaxTTL time.Duration
}

// LoadCapacityCooldownConfig reads the EIGENINFERENCE_CAPACITY_COOLDOWN_* env
// tunables, falling back to the defaults and clamping nonsensical values
// (non-positive durations revert to defaults; MaxTTL is raised to BaseTTL).
func LoadCapacityCooldownConfig() CapacityCooldownConfig {
	cfg := CapacityCooldownConfig{
		Threshold: env.EnvInt(envCapacityCooldownThreshold, DefaultCapacityCooldownThreshold),
		Window:    time.Duration(env.EnvInt(envCapacityCooldownWindowSecs, int(defaultCapacityCooldownWindow/time.Second))) * time.Second,
		BaseTTL:   time.Duration(env.EnvInt(envCapacityCooldownTTLSecs, int(defaultCapacityCooldownTTL/time.Second))) * time.Second,
		MaxTTL:    time.Duration(env.EnvInt(envCapacityCooldownMaxTTLSecs, int(defaultCapacityCooldownMaxTTL/time.Second))) * time.Second,
	}
	if cfg.Window <= 0 {
		cfg.Window = defaultCapacityCooldownWindow
	}
	if cfg.BaseTTL <= 0 {
		cfg.BaseTTL = defaultCapacityCooldownTTL
	}
	if cfg.MaxTTL < cfg.BaseTTL {
		cfg.MaxTTL = cfg.BaseTTL
	}
	return cfg
}

// RecordCapacityRejectProjected records a rejection using the caller's budget
// snapshot. deratePair gates the
// gray-box capacity-503 rate window (true only for genuine capacity rejects);
// armClamp gates the budget clamp (false only for request-deterministic
// rejects, which indict the request rather than the provider). The cooldown
// strike is fed on all paths.
//
// The pair's budget snapshot (does the provider currently report a token
// budget for the model?) is read under p.mu BEFORE the gate is taken — the
// lock order is p.mu → gate.mu, never the reverse. Only gate.mu is then held;
// never r.mu.
func (r *Directory) RecordCapacityRejectProjected(providerID, modelID string, deratePair, armClamp, budgetReported bool) (tripped bool) {
	if providerID == "" || modelID == "" {
		return false
	}
	hold := r.lockGate(r.gateForSession(providerID), "capacity_reject")
	defer hold.unlock()
	g := hold.g
	now := r.now()
	defer g.updatedLocked(now)

	// Gray-box trackers ride the SAME classified entry point but have their own
	// kill switches, independent of the cooldown threshold: the budget clamp
	// stops admission believing the pair's stale heartbeat budget immediately
	// (budget_clamp.go), and the rate window accumulates the reject side of the
	// capacity-503 rate (capacity_rate.go — accepts deliberately do NOT reset
	// it, unlike the strike streak below). The rate window is fed ONLY for a
	// derating reject: a cold-load lifecycle miss (deratePair=false) is warm-up,
	// not capacity dishonesty, and must not accumulate a rate the window can
	// never reset off. The clamp is armed only when the reject indicts the
	// PROVIDER (armClamp=false for request-deterministic rejects — an oversized
	// prompt says nothing about the pair's budget honesty).
	if armClamp {
		g.recordBudgetClampLocked(r.budgetClampCfg, modelID, budgetReported, now)
	}
	if deratePair {
		g.recordCapacityRateRejectLocked(r.capacityRateCfg, modelID, now)
	}

	cfg := r.capacityCooldownCfg
	if cfg.Threshold <= 0 {
		return false // disabled via EIGENINFERENCE_CAPACITY_COOLDOWN_THRESHOLD=0
	}

	// Slide the window: keep only strikes still inside it, then add this one.
	strikes := g.capacityRejectStrikes[modelID]
	kept := strikes[:0]
	for _, ts := range strikes {
		if now.Sub(ts) < cfg.Window {
			kept = append(kept, ts)
		}
	}
	kept = append(kept, now)
	g.capacityRejectStrikes[modelID] = kept

	// Active cooldown: record only — never extend or re-arm (see doc above).
	if e, ok := g.capacityCooldowns[modelID]; ok && now.Before(e.expiry) {
		return false
	}

	trips := g.capacityCooldownTrips[modelID]
	// A fresh pair (trips == 0) needs the full threshold inside the window. A
	// half-open pair (trips > 0: tripped before, no accept since, cooldown
	// expired → this reject IS the failed re-probe) re-arms immediately.
	if trips == 0 && len(kept) < cfg.Threshold {
		return false
	}

	// Arm/re-arm: fresh entry with an unclaimed probe slot for the NEXT expiry.
	g.capacityCooldowns[modelID] = &capacityCooldownEntry{expiry: now.Add(capacityCooldownBackoff(cfg, trips))}
	g.capacityCooldownTrips[modelID] = trips + 1
	return true
}

// ClaimCapacityProbe atomically checks and claims a half-open probe, validating
// the reference against any rebind since resolution.
func (r *Directory) ClaimCapacityProbe(ref Reference, model string, now time.Time) bool {
	ref, has := r.refHasPairState(ref, gateFlagCapacityCooldown)
	if !has {
		return true
	}
	hold := r.lockGate(ref, "capacity_probe")
	if hold.g == nil {
		return true
	}
	// Release directly, not via hold.unlock(): the caller holds p.mu (and
	// r.mu in global commit mode), and the observer's DogStatsD emit must
	// never run inside those sections. The probe's gate wait is therefore not
	// reported; the recorders' waits on the same gates are.
	defer hold.g.mu.Unlock()
	return hold.g.tryClaimCapacityProbeLocked(model, now)
}

// tryClaimCapacityProbeLocked is the check-and-claim itself. Caller holds
// g.mu (lockGate has validated the gate is the session's current one).
func (g *State) tryClaimCapacityProbeLocked(model string, now time.Time) bool {
	assessment := g.capacityAssessmentLocked(model)
	if !assessment.Present {
		return true
	}
	decision, claimed := assessment.Decision.claim(now)
	g.capacityCooldowns[model].probeAt = decision.ProbeAt
	return claimed
}

// PrepareCapacityAccept resolves an accept's identity and whether the caller
// needs a provider budget snapshot before acquiring the gate lock.
func (r *Directory) PrepareCapacityAccept(providerID, modelID string, countRateOutcome bool) (ref Reference, needsBudget, ok bool) {
	if providerID == "" || modelID == "" {
		return Reference{}, false, false
	}
	// A straggling accept creates an identity only when it has a rate outcome
	// to record. Resolve clamp presence before the caller snapshots its provider.
	ref = r.lookupSessionGateRef(providerID)
	if ref.g == nil {
		if !countRateOutcome || r.capacityRateCfg.PenaltyMs <= 0 {
			return Reference{}, false, false
		}
		ref = r.gateForSession(providerID)
	}
	ref, needsBudget = r.refHasPairState(ref, gateFlagBudgetClamp)
	return ref, needsBudget, true
}

// ApplyCapacityAccept applies the accept after the caller has captured any
// needed budget snapshot, without acquiring a provider lock under a gate lock.
// A delayed recorder retains newer strikes, rebuilds their cooldown with fresh
// backoff, and proves clamp release only if observed after the clamp was armed.
// The rate window records apply time to stay ordered. A zero or future
// observation is treated as now.
func (r *Directory) ApplyCapacityAccept(ref Reference, modelID string, observedAt time.Time, countRateOutcome bool, heartbeatAt time.Time, rawRemaining int64, budgetReported bool) (rateOutcomeRecorded bool) {
	hold := r.lockGate(ref, "capacity_accept")
	defer hold.unlock()
	g := hold.g
	if g == nil {
		return false
	}

	now := r.now()
	if observedAt.IsZero() || observedAt.After(now) {
		observedAt = now
	}
	if strikes := g.capacityRejectStrikes[modelID]; len(strikes) > 0 {
		kept := strikes[:0]
		for _, stamp := range strikes {
			if stamp.After(observedAt) {
				kept = append(kept, stamp)
			}
		}
		if len(kept) == 0 {
			delete(g.capacityRejectStrikes, modelID)
		} else {
			g.capacityRejectStrikes[modelID] = kept
		}
	}
	g.rebuildCapacityCooldownLocked(r.capacityCooldownCfg, modelID)
	// Gray-box trackers: the accept is PROOF for the clamp's release condition
	// (b) — never an instant release, which still needs a strictly-fresher
	// heartbeat with meaningful headroom — and ONE served outcome for the rate
	// window (which deliberately has NO reset semantics: the accept/reject mix
	// IS the signal). Then drop the entry if it is now inactive (this accept
	// completed the release proof, the TTL lapsed, or it was armed budgetless):
	// a lingering inactive entry would keep re-blocking the identity's next
	// budgetless reconnect window. The snapshot was read before the gate was
	// taken (lock order p.mu → gate.mu), so two benign races exist: a clamp
	// armed in between sees a zero snapshot and keeps holding, and a heartbeat
	// delivered in between already ran its own release pass before
	// acceptedSince was set, so the release lands on the NEXT heartbeat or
	// accept. Neither can release early.
	if e, hasClamp := g.budgetClamps[modelID]; hasClamp {
		if !e.clampedAt.After(observedAt) {
			e.acceptedSince = true
		}
		g.dropInactiveBudgetClampLocked(r.budgetClampCfg, modelID, heartbeatAt, rawRemaining, budgetReported, now)
	}
	if countRateOutcome {
		rateOutcomeRecorded = g.recordCapacityRateAcceptLocked(r.capacityRateCfg, modelID, now)
	}
	g.ejectionCapacityStreak = capacityStreak{}
	if g.ejectionLastTripCapacity {
		g.ejectionTrips = 0
		g.ejectionLastTripCapacity = false
	}
	g.updatedLocked(now)
	return rateOutcomeRecorded
}

// capacityCooled reports whether routing should skip the pair. READ-ONLY (no
// lazy delete, no claim): lock-free "no cooldown entry on any model" fast
// path, otherwise one short gate.mu section. nil-safe.
//
// Half-open semantics: inside the TTL the gate is closed. Once now reaches the
// expiry it opens ONLY while no probe claim is fresh — the first reservation
// through claims the probe (tryClaimCapacityProbe, at commit), which closes
// the gate again for everyone else until the probe's outcome lands (accept
// deletes the entry; reject re-arms it) or the claim goes stale after
// capacityProbeOutcomeWindow (a lost probe must not wedge the pair).
func (g *State) capacityCooled(modelID string, now time.Time) bool {
	if !g.hasPairState(gateFlagCapacityCooldown) {
		return false
	}
	g = g.lockResolved()
	defer g.mu.Unlock()
	assessment := g.capacityAssessmentLocked(modelID)
	return assessment.Present && assessment.Decision.Active(now)
}

// capacityCooldownBackoff returns the cooldown TTL for a pair that has already
// tripped `trips` times (0 = first trip): BaseTTL * 2^trips, capped at MaxTTL.
// The loop avoids overflowing the shift for large trip counts (mirrors
// providerBreakerBackoff).
func capacityCooldownBackoff(cfg CapacityCooldownConfig, trips int) time.Duration {
	ttl := cfg.BaseTTL
	for i := 0; i < trips && ttl < cfg.MaxTTL; i++ {
		ttl *= 2
	}
	if ttl > cfg.MaxTTL {
		ttl = cfg.MaxTTL
	}
	return ttl
}

// rebuildCapacityCooldownLocked applies the post-accept strike history from a
// fresh breaker. The caller has removed every strike answered by the accept.
func (g *State) rebuildCapacityCooldownLocked(cfg CapacityCooldownConfig, modelID string) {
	assessment := g.capacityAssessmentLocked(modelID)
	delete(g.capacityCooldowns, modelID)
	delete(g.capacityCooldownTrips, modelID)
	decision := RebuildCapacityCooldown(cfg, assessment.Strikes, assessment.Decision)
	if decision.Trips == 0 {
		return
	}
	g.capacityCooldowns[modelID] = &capacityCooldownEntry{expiry: decision.RetryAfter, probeAt: decision.ProbeAt}
	g.capacityCooldownTrips[modelID] = decision.Trips
}
