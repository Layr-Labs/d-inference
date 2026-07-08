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
// accepts (first content chunk / clean completion), and any accept resets the
// pair's strike streak (RecordCapacityAccept). Only Threshold-many capacity
// rejects inside Window with NO accept in between — the black-hole signature —
// trip the cooldown. Keyed per (provider, model) with a struct key (no
// delimiter aliasing), mirroring error_cooldown.go.
//
// RE-PROBE + BACKOFF — TRUE HALF-OPEN. A trip quarantines the pair for
// BaseTTL (default 120s). After expiry EXACTLY ONE request passes as the
// probe: the routing gate opens only while no probe claim is fresh, and
// ReserveProviderEx claims the probe (claimCapacityProbeLocked, under the
// r.mu write lock held for the whole reservation, so concurrent reservations
// serialize) the moment it reserves the pair — every other request keeps
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
// State is keyed by the provider's STABLE fault identity (faultKeyLocked:
// serial → SE-key → account → session fallback), so a reconnect cannot reset
// a black hole's streak, cooldown, or backoff trip count — the same
// reconnect-proofing as error_cooldown.go and provider_breaker.go. Maps are
// bounded by the same opportunistic >1024 sweep. r.mu discipline and the
// transition-bool return also mirror error_cooldown.go.

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
// cooldown. Fields are written ONLY under the r.mu write lock (arm/re-arm in
// RecordCapacityReject, probe claim in claimCapacityProbeLocked); the routing
// gate reads them under either lock mode.
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

// capacityRejectKey identifies a capacity-cooldown bucket. A struct key (vs a
// delimiter-joined string) cannot alias across ids containing the delimiter.
type capacityRejectKey struct {
	ProviderID string
	ModelID    string
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
// cold "model not loaded" lazy-load 404 on first touch. It feeds the
// black-hole cooldown (a box that 404s FOREVER with zero accepts is still a
// black hole, caught by the zero-interleaved-accepts discriminator) and,
// harmlessly, the budget clamp (a budgetless-armed clamp never gates — see
// budgetClampActiveLocked), but it does NOT derate the pair in the gray-box
// capacity-503 RATE window. That window deliberately has NO accept-reset, so
// counting a healthy box's normal reload misses would accumulate a false
// reject rate and penalize it as if its reported budget were dishonest. The
// api layer routes cold "not loaded"/"no model loaded" rejections here;
// genuine capacity/token-budget 503s go to RecordCapacityReject and DO derate.
func (r *Registry) RecordCapacityRejectLifecycle(providerID, modelID string) (tripped bool) {
	return r.recordCapacityReject(providerID, modelID, false, true)
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

// recordCapacityReject is the shared implementation. deratePair gates the
// gray-box capacity-503 rate window (true only for genuine capacity rejects);
// armClamp gates the budget clamp (false only for request-deterministic
// rejects, which indict the request rather than the provider). The cooldown
// strike is fed on all paths.
func (r *Registry) recordCapacityReject(providerID, modelID string, deratePair, armClamp bool) (tripped bool) {
	if providerID == "" || modelID == "" {
		return false
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	now := time.Now()

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
	clampKey := capacityRejectKey{ProviderID: r.faultKeyLocked(providerID), ModelID: modelID}
	if armClamp {
		r.recordBudgetClampLocked(clampKey, r.providerReportsTokenBudgetLocked(providerID, modelID), now)
	}
	if deratePair {
		r.recordCapacityRateRejectLocked(clampKey, now)
	}

	cfg := r.capacityCooldownCfg
	if cfg.Threshold <= 0 {
		return false // disabled via EIGENINFERENCE_CAPACITY_COOLDOWN_THRESHOLD=0
	}

	// Opportunistic sweep (mirrors error_cooldown.go): session provider ids are
	// per-connection UUIDs that never get re-keyed — bound the maps by dropping
	// expired/idle entries once they grow.
	if len(r.capacityCooldowns) > 1024 {
		for key, e := range r.capacityCooldowns {
			// Half-open entries live PAST their expiry by design: the fresh
			// probe claim (probeAt) is the only thing keeping the gate closed
			// while the single probe's outcome is pending. Sweeping such an
			// entry would reopen the gate mid-probe and leak a thundering herd
			// through the post-expiry window — keep entries whose claim is
			// still fresh; they self-resolve within capacityProbeOutcomeWindow.
			if !now.Before(e.expiry) &&
				(e.probeAt.IsZero() || !now.Before(e.probeAt.Add(capacityProbeOutcomeWindow))) {
				delete(r.capacityCooldowns, key)
				delete(r.capacityCooldownTrips, key)
			}
		}
	}
	if len(r.capacityRejectStrikes) > 1024 {
		for key, strikes := range r.capacityRejectStrikes {
			if len(strikes) == 0 || !strikes[len(strikes)-1].Add(cfg.Window).After(now) {
				delete(r.capacityRejectStrikes, key)
			}
		}
	}

	key := capacityRejectKey{ProviderID: r.faultKeyLocked(providerID), ModelID: modelID}

	// Slide the window: keep only strikes still inside it, then add this one.
	strikes := r.capacityRejectStrikes[key]
	kept := strikes[:0]
	for _, ts := range strikes {
		if now.Sub(ts) < cfg.Window {
			kept = append(kept, ts)
		}
	}
	kept = append(kept, now)
	r.capacityRejectStrikes[key] = kept

	// Active cooldown: record only — never extend or re-arm (see doc above).
	if e, ok := r.capacityCooldowns[key]; ok && now.Before(e.expiry) {
		return false
	}

	trips := r.capacityCooldownTrips[key]
	// A fresh pair (trips == 0) needs the full threshold inside the window. A
	// half-open pair (trips > 0: tripped before, no accept since, cooldown
	// expired → this reject IS the failed re-probe) re-arms immediately.
	if trips == 0 && len(kept) < cfg.Threshold {
		return false
	}

	// Arm/re-arm: fresh entry with an unclaimed probe slot for the NEXT expiry.
	r.capacityCooldowns[key] = &capacityCooldownEntry{expiry: now.Add(capacityCooldownBackoff(cfg, trips))}
	r.capacityCooldownTrips[key] = trips + 1
	return true
}

// claimCapacityProbeLocked claims the single half-open probe for an EXPIRED
// cooldown entry, called by ReserveProviderEx at reservation commit — the
// moment a request is actually bound to the pair. Caller MUST hold the r.mu
// WRITE lock (ReserveProviderEx does, for the whole selection+reservation), so
// concurrent reservations serialize: the first to reserve the pair claims the
// probe, and the gate (capacityCooldownActiveLocked) closes for everyone else
// until the probe's outcome lands or the claim goes stale. A no-op for pairs
// with no cooldown entry (the overwhelmingly common case — one map lookup) or
// one still inside its TTL (unreachable via routing, but harmless).
func (r *Registry) claimCapacityProbeLocked(providerID, modelID string, now time.Time) {
	e, ok := r.capacityCooldowns[capacityRejectKey{ProviderID: r.faultKeyLocked(providerID), ModelID: modelID}]
	if !ok || now.Before(e.expiry) {
		return
	}
	if e.probeAt.IsZero() || !now.Before(e.probeAt.Add(capacityProbeOutcomeWindow)) {
		e.probeAt = now
	}
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
// signal. An ACTIVE ejection window (healthEjectionUntil still in the future)
// is also left untouched: ejection doesn't cancel in-flight work, so content
// can flow from an ejected node, and lifting the quarantine early on it would
// defeat the cooldown — recovery goes through the half-open success probe.
// It returns whether a capacity-503 RATE outcome was actually recorded for
// this accept (see RecordCapacityAcceptOutcome) so commit-time callers can
// stamp the request (MarkRateOutcomeCounted) and the completion-time accept
// can decide whether the request still owes its one rate outcome.
func (r *Registry) RecordCapacityAccept(providerID, modelID string) (rateOutcomeRecorded bool) {
	return r.RecordCapacityAcceptOutcome(providerID, modelID, true)
}

// RecordCapacityAcceptOutcome is RecordCapacityAccept with explicit control
// over the capacity-503 RATE window's denominator (capacity_rate.go).
// countRateOutcome=true OFFERS one served-dispatch outcome; whether it was
// actually RECORDED is the return value — the rate window only stores accepts
// while the pair has a reject in-window (recordCapacityRateAcceptLocked), so a
// commit that lands before any reject is an offer that records nothing. The
// api layer offers at the commit point (first content chunk) and stamps the
// request when the offer recorded (MarkRateOutcomeCounted); the completion-
// time accept re-offers ONLY when the commit-time offer did not record
// (!RateOutcomeCountedSafe) — so a long stream that committed pre-reject and
// completed during the reject window still enters the denominator exactly
// once, and a request whose commit already recorded cannot double-count and
// dilute the reject rate. The cooldown/streak/clamp accept semantics below
// are identical for both values (belt-and-braces accepts stay harmless there).
func (r *Registry) RecordCapacityAcceptOutcome(providerID, modelID string, countRateOutcome bool) (rateOutcomeRecorded bool) {
	if providerID == "" || modelID == "" {
		return false
	}
	// Fast path: this runs once per served request, and for a healthy pair all
	// the maps are empty — check under the read lock so the serving hot path
	// does not serialize on r.mu write acquisition. A rate-outcome accept only
	// needs the write lock when the pair has rejects in its rate window
	// (recordCapacityRateAcceptLocked is what builds the denominator, and a
	// zero-reject pair's rate is 0 regardless — capacityRatePenaltyLocked
	// fast-exits on rejects==0 — so skipping the append loses nothing).
	r.mu.RLock()
	key := capacityRejectKey{ProviderID: r.faultKeyLocked(providerID), ModelID: modelID}
	_, hasStrikes := r.capacityRejectStrikes[key]
	_, hasCooldown := r.capacityCooldowns[key]
	_, hasTrips := r.capacityCooldownTrips[key]
	_, hasClamp := r.budgetClamps[key]
	hasRateRejects := len(r.capacityRateRejects[key]) > 0
	_, hasNodeStreak := r.healthEjectionCapacityStreaks[key.ProviderID]
	capacityTripped := r.healthEjectionLastTripCapacity[key.ProviderID]
	r.mu.RUnlock()
	if !hasStrikes && !hasCooldown && !hasTrips && !hasClamp && !hasRateRejects && !hasNodeStreak && !capacityTripped {
		// Nothing recorded: with no reject in the rate window the accept
		// would not be stored anyway (see recordCapacityRateAcceptLocked).
		return false
	}
	r.mu.Lock()
	now := time.Now()
	key = capacityRejectKey{ProviderID: r.faultKeyLocked(providerID), ModelID: modelID}
	delete(r.capacityRejectStrikes, key)
	delete(r.capacityCooldowns, key)
	delete(r.capacityCooldownTrips, key)
	// Gray-box trackers: the accept is PROOF for the clamp's release condition
	// (b) — never an instant release, which still needs a strictly-fresher
	// heartbeat with meaningful headroom — and ONE served outcome for the rate
	// window (which deliberately has NO reset semantics: the accept/reject mix
	// IS the signal). Then drop the entry if it is now inactive (this accept
	// completed the release proof, the TTL lapsed, or it was armed budgetless):
	// a lingering inactive entry would keep every later accept for the pair off
	// the read-lock fast path above and would re-block the identity's next
	// budgetless reconnect window.
	r.noteBudgetClampAcceptLocked(key)
	r.dropInactiveBudgetClampLocked(providerID, modelID, now)
	if countRateOutcome {
		rateOutcomeRecorded = r.recordCapacityRateAcceptLocked(key, now)
	}
	delete(r.healthEjectionCapacityStreaks, key.ProviderID)
	if r.healthEjectionLastTripCapacity[key.ProviderID] {
		delete(r.healthEjectionTrips, key.ProviderID)
		delete(r.healthEjectionLastTripCapacity, key.ProviderID)
	}
	r.mu.Unlock()
	return rateOutcomeRecorded
}

// CapacityCooldownActive reports whether the (provider, model) pair is
// currently quarantined by the capacity-reject cooldown. Exposed for tests and
// observability; the routing hot path uses capacityCooldownActiveLocked under
// the already-held r.mu.
func (r *Registry) CapacityCooldownActive(providerID, modelID string) bool {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return r.capacityCooldownActiveLocked(providerID, modelID, time.Now())
}

// capacityCooldownActiveLocked reports whether routing should skip the pair.
// READ-ONLY (no lazy delete, no claim) — some callers hold only r.mu.RLock.
// Caller holds r.mu in either mode (mirrors inferenceErrorCooldownActiveLocked).
//
// Half-open semantics: inside the TTL the gate is closed. Once now reaches the
// expiry it opens ONLY while no probe claim is fresh — the first reservation
// through claims the probe (claimCapacityProbeLocked, write lock), which
// closes the gate again for everyone else until the probe's outcome lands
// (accept deletes the entry; reject re-arms it) or the claim goes stale after
// capacityProbeOutcomeWindow (a lost probe must not wedge the pair).
func (r *Registry) capacityCooldownActiveLocked(providerID, modelID string, now time.Time) bool {
	e, ok := r.capacityCooldowns[capacityRejectKey{ProviderID: r.faultKeyLocked(providerID), ModelID: modelID}]
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
