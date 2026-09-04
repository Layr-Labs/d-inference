package registry

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/env"
)

// Capacity-reject routing cooldown.
//
// Prod incident (2026-07): 7 provider boxes (64GB, gemma-4-26b-8bit, v0.7.2)
// rejected 100% of dispatched requests with the capacity string
// ("token_budget_exhausted", classified 503) from their FIRST request after
// registration — ~9,000 rejections in 30 minutes, zero successes — while ~170
// healthy boxes for the same model sat underutilized. The router kept picking
// them because (a) their heartbeats reported near-zero active tokens, so the
// cost-based scheduler scored them best, and (b) capacity-class failures are
// DELIBERATELY invisible to reputation, the shape-keyed inference-error
// breaker (error_cooldown.go skips 503), and the node-health breaker
// (provider_breaker.go ignores capacity sheds). That invisibility is sound
// policy for OCCASIONAL capacity rejects — a busy box must never be punished
// for shedding load — but catastrophic for a box that rejects EVERYTHING: it
// becomes a dispatch black hole.
//
// DISCRIMINATOR — zero interleaved accepts. Transient fullness is NORMAL: a
// saturated box legitimately capacity-rejects while it is ALSO serving. What
// separates pathology from fullness is that a serving box keeps producing
// accepts (first content chunk / clean completion), and any accept clears the
// strikes recorded up to the instant it was OBSERVED (RecordCapacityAccept /
// RecordCapacityAcceptObserved — a strike recorded after that instant is not
// "before an accept" and survives an accept that is applied late). Only
// Threshold-many capacity rejects inside Window with NO accept in between —
// the black-hole signature — trip the cooldown. Keyed per (provider, model) with a struct key (no
// delimiter aliasing), mirroring error_cooldown.go.
//
// RE-PROBE + BACKOFF — TRUE HALF-OPEN. A trip quarantines the pair for
// BaseTTL (default 120s). After expiry EXACTLY ONE request passes as the
// probe: the routing gate opens only while no probe claim is fresh, and the
// reservation commit claims the probe (tryClaimCapacityProbe — check and claim
// in one gate.mu section, so concurrent reservations for the identity
// serialize there) the moment it reserves the pair — every other request keeps
// seeing the cooldown until the probe's outcome lands. Accept → all state
// cleared, the pair is fully re-admitted (a genuinely-full box that recovered
// gets traffic back). Reject → immediate re-arm with an exponentially doubled
// TTL, capped at MaxTTL (default 10 min) — a persistent black hole costs ONE
// bounced probe per cycle, with no thundering-herd leak in the post-expiry
// window. If the probe's outcome never lands (the request died before any
// terminal reached the breaker hooks), the claim goes stale after
// capacityProbeOutcomeWindow and the next reservation may probe again.
//
// NOT bypassed by the selectBestCandidateLockedFull fail-open rescan
// (consistent with the other pair-scoped cooldowns): if every pair for a model
// is capacity-cooled, the fleet genuinely has zero accepting capacity and the
// truthful outcome is the queue/429 path, not a guaranteed-reject dispatch.
// TTLs stagger, so re-probes trickle back on their own.
//
// State lives on the provider's STABLE fault identity gate (gate_state.go:
// serial → SE-key → account → session fallback), so a reconnect cannot reset
// a black hole's streak, cooldown, or backoff trip count — the same
// reconnect-proofing as error_cooldown.go and provider_breaker.go. Guarded by
// gate.mu; the transition-bool return mirrors error_cooldown.go.

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
	defaultCapacityCooldownThreshold = 5
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

// capacityCooldownConfig carries the env-tunable cooldown parameters.
type capacityCooldownConfig struct {
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

// loadCapacityCooldownConfig reads the EIGENINFERENCE_CAPACITY_COOLDOWN_* env
// tunables, falling back to the defaults and clamping nonsensical values
// (non-positive durations revert to defaults; MaxTTL is raised to BaseTTL).
func loadCapacityCooldownConfig() capacityCooldownConfig {
	cfg := capacityCooldownConfig{
		Threshold: env.EnvInt(envCapacityCooldownThreshold, defaultCapacityCooldownThreshold),
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

// RecordCapacityReject records one capacity-class rejection (token budget /
// KV headroom / queue full / draining / …) for the (provider, model) pair.
// The api layer classifies which provider errors qualify
// (isCapacityRejectStrike) — request-shape context overflows never reach here.
//
// Returns true ONLY on the transition into cooldown so callers can emit the
// capacity_cooldown_tripped metric/log without double-counting. Trip
// conditions:
//   - fresh pair (never tripped, or accept-cleared): Threshold strikes inside
//     Window with zero interleaved accepts;
//   - half-open pair (tripped before, cooldown expired, still no accept): the
//     FIRST post-expiry reject re-arms immediately with doubled backoff.
//
// While a cooldown is ACTIVE, strikes are still recorded (in-flight stragglers
// dispatched before the trip land here) but never extend or re-arm it —
// otherwise stragglers could push recovery out indefinitely.
//
// This is the DERATING entry point: a genuine capacity/token-budget 503 feeds
// all three trackers, including the gray-box capacity-503 rate window
// (capacity_rate.go). A benign cold "model not loaded" lazy-load miss must go
// to RecordCapacityRejectLifecycle instead so it does NOT derate the rate, and
// a provably request-deterministic reject (oversized prompt — identical
// fleet-wide) must go to RecordCapacityRejectRequestShape so it arms NO
// gray-box state at all.
func (r *Registry) RecordCapacityReject(providerID, modelID string) (tripped bool) {
	return r.recordCapacityReject(providerID, modelID, true, true)
}

// RecordCapacityRejectLifecycle records a BENIGN lifecycle capacity miss — a
// cold "model not loaded" lazy-load 404 on first touch, or the identical miss
// after the 1h idle-unload (the normal fleet re-warm cycle). It feeds ONLY the
// black-hole cooldown: a box that 404s FOREVER with zero accepts is still a
// black hole, caught by the zero-interleaved-accepts discriminator.
//
// It arms NEITHER gray-box tracker. Not the rate window (no accept-reset, so
// counting normal reload misses would accumulate a false reject rate) — and
// not the budget clamp either: the lifecycle classification takes PRECEDENCE
// over whatever the budget snapshot says. A provider that idle-unloaded the
// model AFTER its last heartbeat still SHOWS the slot budget in the stale
// snapshot, so keying the exemption on snapshot budgetless-ness (arming a
// "budgetless" entry) would arm a REAL gating clamp from a routine re-warm
// 404 — and with the clamp blocking dispatch, no accept could land to prove
// release, stranding the pair until TTL. A cold miss is a statement about
// model residency, never about token-budget honesty, so it must not touch the
// clamp regardless of the snapshot. The api layer routes cold "not loaded"/
// "no model loaded" rejections here; genuine capacity/token-budget 503s go to
// RecordCapacityReject and feed everything.
func (r *Registry) RecordCapacityRejectLifecycle(providerID, modelID string) (tripped bool) {
	return r.recordCapacityReject(providerID, modelID, false, false)
}

// RecordCapacityRejectRequestShape records a capacity-vocabulary rejection the
// api layer has PROVEN request-deterministic — a "batch token budget" reject
// from a provider whose reported budget is not below the model context, so the
// binding term was the model context and every provider rejects the same
// prompt identically (classifyRejection: rejectionDeterministicUnservable).
// Such a reject indicts the REQUEST, not the provider: it must arm NEITHER the
// one-shot budget clamp NOR the no-reset rate window, or a single oversized
// prompt would clamp/derate a healthy pair (and, for the clamp, block the very
// dispatches whose accepts prove release).
//
// It still counts a cooldown STRIKE, deliberately: isCapacityRejectStrike
// includes "batch token budget" because a box misreporting a huge budget
// rejects NORMAL prompts with exactly this string — and such a box classifies
// as request-deterministic here too (its advertised budget >= context IS the
// lie). The cooldown's zero-interleaved-accepts discriminator is what makes
// that safe for healthy pairs (threshold 5 in 60s with NO accept; any accept
// resets the streak), a safety the clamp and rate window by design lack.
func (r *Registry) RecordCapacityRejectRequestShape(providerID, modelID string) (tripped bool) {
	return r.recordCapacityReject(providerID, modelID, false, false)
}

// RecordCapacityRejectBusy records a typed admission-timeout capacity signal
// (InferenceErrorMessage terminal_cause=admission_timeout): the provider
// accepted the dispatch but its engine could not admit the request before the
// admission lease expired — a healthy-but-busy statement, never a fault and
// never a token-budget-honesty statement. It feeds ONLY the black-hole
// cooldown strike (the zero-interleaved-accepts discriminator keeps a serving
// box safe): a pair that admission-times-out EVERYTHING with zero accepts is
// a routing black hole exactly like a 100%-capacity-rejecting one. It arms
// NEITHER gray-box tracker — not the budget clamp (an admission timeout says
// nothing about the reported token budget, and a false clamp blocks the very
// dispatches whose accepts prove release) and not the no-accept-reset
// capacity-503 rate window (transient load would accumulate a false reject
// rate against a healthy pair).
func (r *Registry) RecordCapacityRejectBusy(providerID, modelID string) (tripped bool) {
	return r.recordCapacityReject(providerID, modelID, false, false)
}

// recordCapacityReject is the shared implementation. deratePair gates the
// gray-box capacity-503 rate window (true only for genuine capacity rejects);
// armClamp gates the budget clamp (false only for request-deterministic
// rejects, which indict the request rather than the provider). The cooldown
// strike is fed on all paths.
//
// The pair's budget snapshot (does the provider currently report a token
// budget for the model?) is read under p.mu BEFORE the gate is taken — the
// lock order is p.mu → gate.mu, never the reverse. Only gate.mu is then held;
// never r.mu.
func (r *Registry) recordCapacityReject(providerID, modelID string, deratePair, armClamp bool) (tripped bool) {
	if providerID == "" || modelID == "" {
		return false
	}
	budgetReported := false
	if armClamp {
		budgetReported = providerReportsTokenBudget(r.sessionProvider(providerID), modelID)
	}
	hold := r.lockGate(r.gateForSession(providerID), "capacity_reject")
	defer hold.unlock()
	g := hold.g
	now := time.Now()
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

// tryClaimCapacityProbe claims the single half-open probe for an EXPIRED
// cooldown entry, called by the reservation commit (under p.mu, in both
// commit modes) at the moment a request is actually bound to the pair. The
// check and the claim are ONE gate.mu section, so concurrent commits for the
// same identity serialize here even though the commit itself no longer holds
// the registry write lock: the first to reserve the pair claims the probe and
// every later one sees the fresh claim.
//
// Returns false when the pair's gate is CLOSED right now — inside its TTL, or
// expired with another request's probe claim still fresh — so the caller
// rejects the reservation instead of leaking a second probe through the
// post-expiry window. Returns true (a no-op) for a pair with no cooldown entry
// — the overwhelmingly common case, one lock-free flag load — and true after
// claiming an unclaimed or stale slot. nil-safe (a bare Provider has no gate).
//
// The claim is a mutation, so it goes through lockGate like the recorders: a
// rebind that lands between loading p.gate and taking the lock moves the
// cooldown entry to the session's new gate, and a claim made on the old
// (emptied) gate would find no entry and admit — a leaked probe through a
// cooled pair. lockGate sees p.gate moved and re-resolves. Lock order: the
// caller holds p.mu; gatesMu (on a re-resolve) and gate.mu nest under it.
func (r *Registry) tryClaimCapacityProbe(p *Provider, model string, now time.Time) bool {
	return r.claimCapacityProbeRef(r.probeGateRef(p), model, now)
}

// probeGateRef resolves the gate the commit's probe claim targets: the
// connected Provider's cached p.gate (no lock), remembering p so lockGate can
// tell when the session rebound between this load and the lock. A Provider
// that was never registered (bare test objects) falls back to the session
// lookup; nil resolves to no gate.
func (r *Registry) probeGateRef(p *Provider) gateRef {
	if p == nil {
		return gateRef{}
	}
	if g := p.gate.Load(); g != nil {
		return gateRef{g: g.resolve(), p: p, session: p.ID}
	}
	return r.lookupSessionGateRef(p.ID)
}

// claimCapacityProbeRef is tryClaimCapacityProbe on an already-resolved ref
// (split out so a test can interpose a rebind between resolution and claim).
func (r *Registry) claimCapacityProbeRef(ref gateRef, model string, now time.Time) bool {
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
func (g *gateState) tryClaimCapacityProbeLocked(model string, now time.Time) bool {
	e, ok := g.capacityCooldowns[model]
	if !ok {
		return true
	}
	if now.Before(e.expiry) {
		return false
	}
	if e.probeAt.IsZero() || !now.Before(e.probeAt.Add(capacityProbeOutcomeWindow)) {
		e.probeAt = now
		return true
	}
	return false
}

// RecordCapacityAccept records that the (provider, model) pair ACCEPTED work —
// the api layer calls it on the first content-bearing chunk (commit) and on
// clean completion. It clears the pair's reject streak, any active cooldown,
// and the exponential-backoff trip count: an accept proves the pair admits
// work, which is exactly the discriminator that separates a busy-but-serving
// box (must NEVER trip) from a black hole (zero accepts). The NODE-level
// capacity streak (health_ejection.go) is cleared for the same reason: a box
// mid-way through a long generation that legitimately sheds concurrent
// dispatches must keep vouching for itself at first content — waiting for the
// completion-time success (RecordProviderServeOutcome) would let transient
// fullness during a long stream masquerade as the zero-accepts black-hole
// signature.
//
// A CAPACITY-shaped ejection's half-open state (trips + last-trip marker) is
// disarmed by the same logic: the half-open instant re-arm exists so a
// black-hole probe that bounces re-ejects in one strike, but a node producing
// content has just disproven the black-hole signature, so a single concurrent
// capacity shed racing the probe must need a full fresh zero-success streak,
// not one strike. A FAULT-shaped ejection's trips are deliberately preserved —
// first content says nothing about fault behavior, and wiping the exponential
// backoff on any served chunk would let a flapping node reset it forever;
// RecordProviderServeOutcome(ok=true) at clean completion is the fault-recovery
// signal. An ACTIVE ejection window (ejectionUntil still in the future) is
// also left untouched: ejection doesn't cancel in-flight work, so content can
// flow from an ejected node, and lifting the quarantine early on it would
// defeat the cooldown — recovery goes through the half-open success probe.
// It returns whether a capacity-503 RATE outcome was recorded for this accept
// (see RecordCapacityAcceptOutcome) so commit-time callers can stamp the request
// (MarkRateOutcomeCounted) and the completion-time accept can decide whether the
// request still owes its one rate outcome.
func (r *Registry) RecordCapacityAccept(providerID, modelID string) (rateOutcomeRecorded bool) {
	return r.RecordCapacityAcceptObserved(providerID, modelID, time.Now(), true)
}

// RecordCapacityAcceptOutcome is RecordCapacityAccept with explicit control
// over the capacity-503 RATE window's denominator (capacity_rate.go).
// countRateOutcome=true OFFERS one served-dispatch outcome; whether it was
// actually RECORDED is the return value. While the tracker is enabled, accepts
// are retained even before the first reject so the five-minute denominator is
// independent of event order. The api layer offers at the commit point (first
// content chunk) and stamps the request when the offer recorded
// (MarkRateOutcomeCounted); the completion-time accept re-offers ONLY when the
// commit-time offer did not record (!RateOutcomeCountedSafe), covering paths
// that never commit content without double-counting streamed requests. The
// cooldown/streak/clamp accept semantics below are identical for both values
// (belt-and-braces accepts stay harmless there).
//
// This takes ONLY the identity's gate.mu
// — never r.mu. The one provider read it may need (the live budget snapshot
// that decides whether an accept RELEASES a clamp) happens under p.mu before
// the gate is taken, and only when the gate's flag word says a clamp exists.
func (r *Registry) RecordCapacityAcceptOutcome(providerID, modelID string, countRateOutcome bool) (rateOutcomeRecorded bool) {
	return r.RecordCapacityAcceptObserved(providerID, modelID, time.Now(), countRateOutcome)
}

// RecordCapacityAcceptObserved applies a first-content accept at its original
// observation time. A delayed recorder retains newer strikes, rebuilds their
// cooldown with fresh backoff, and proves clamp release only if observed after
// the clamp was armed. The rate window records apply time to stay ordered.
// All fault-state mutations remain under gate.mu, never the global registry
// lock. A zero or future observation is treated as now.
func (r *Registry) RecordCapacityAcceptObserved(providerID, modelID string, observedAt time.Time, countRateOutcome bool) (rateOutcomeRecorded bool) {
	if providerID == "" || modelID == "" {
		return false
	}
	// An identity with no gate has nothing to clear; create one only when
	// there is a rate outcome to record, so a straggling accept for a dead
	// session does not file a gate under its id.
	ref := r.lookupSessionGateRef(providerID)
	if ref.g == nil {
		if !countRateOutcome || r.capacityRateCfg.PenaltyMs <= 0 {
			return false
		}
		ref = r.gateForSession(providerID)
	}
	var heartbeatAt time.Time
	var rawRemaining int64
	var budgetReported bool
	ref, hasClamp := r.refHasPairState(ref, gateFlagBudgetClamp)
	if hasClamp {
		heartbeatAt, rawRemaining, budgetReported = providerBudgetSnapshot(r.sessionProvider(providerID), modelID)
	}
	hold := r.lockGate(ref, "capacity_accept")
	defer hold.unlock()
	g := hold.g
	if g == nil {
		return false
	}

	now := time.Now()
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

// CapacityCooldownActive reports whether the (provider, model) pair is
// currently quarantined by the capacity-reject cooldown. Exposed for tests and
// observability.
func (r *Registry) CapacityCooldownActive(providerID, modelID string) bool {
	return r.capacityCooled(providerID, modelID, time.Now())
}

// capacityCooled resolves the session's gate; the scan uses the cached p.gate
// directly.
func (r *Registry) capacityCooled(providerID, modelID string, now time.Time) bool {
	return r.lookupGateForSession(providerID).capacityCooled(modelID, now)
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
func (g *gateState) capacityCooled(modelID string, now time.Time) bool {
	if !g.hasPairState(gateFlagCapacityCooldown) {
		return false
	}
	g = g.lockResolved()
	defer g.mu.Unlock()
	e, ok := g.capacityCooldowns[modelID]
	if !ok {
		return false
	}
	if now.Before(e.expiry) {
		return true
	}
	// Expired: closed to everyone but the single claimed probe while its
	// outcome is pending; open when unclaimed or the claim went stale.
	return !e.probeAt.IsZero() && now.Before(e.probeAt.Add(capacityProbeOutcomeWindow))
}

// capacityCooldownBackoff returns the cooldown TTL for a pair that has already
// tripped `trips` times (0 = first trip): BaseTTL * 2^trips, capped at MaxTTL.
// The loop avoids overflowing the shift for large trip counts (mirrors
// providerBreakerBackoff).
func capacityCooldownBackoff(cfg capacityCooldownConfig, trips int) time.Duration {
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
func (g *gateState) rebuildCapacityCooldownLocked(cfg capacityCooldownConfig, modelID string) {
	previous := g.capacityCooldowns[modelID]
	delete(g.capacityCooldowns, modelID)
	delete(g.capacityCooldownTrips, modelID)
	strikes := g.capacityRejectStrikes[modelID]
	if cfg.Threshold <= 0 || len(strikes) < cfg.Threshold {
		return
	}
	var expiry time.Time
	trips := 0
	for i, strike := range strikes {
		if strike.Before(expiry) || (trips == 0 && i+1 < cfg.Threshold) {
			continue
		}
		expiry = strike.Add(capacityCooldownBackoff(cfg, trips))
		trips++
	}
	entry := &capacityCooldownEntry{expiry: expiry}
	if previous != nil && !previous.probeAt.IsZero() && !previous.probeAt.Before(expiry) {
		entry.probeAt = previous.probeAt
	}
	g.capacityCooldowns[modelID] = entry
	g.capacityCooldownTrips[modelID] = trips
}
