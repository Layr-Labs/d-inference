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
// RE-PROBE + BACKOFF. A trip quarantines the pair for BaseTTL (default 120s).
// After expiry routing re-probes it: a genuinely-full box that recovered gets
// traffic back and its first accept clears ALL state (streak, cooldown, trip
// count). A still-pathological pair re-arms on its FIRST post-expiry reject
// (half-open, like provider_breaker.go) with an exponentially doubled TTL,
// capped at MaxTTL (default 10 min) — so a persistent black hole costs one
// bounced probe per cycle instead of Threshold-many.
//
// NOT bypassed by the selectBestCandidateLockedFull fail-open rescan
// (consistent with the other pair-scoped cooldowns): if every pair for a model
// is capacity-cooled, the fleet genuinely has zero accepting capacity and the
// truthful outcome is the queue/429 path, not a guaranteed-reject dispatch.
// TTLs stagger, so re-probes trickle back on their own.
//
// State is keyed by the per-session provider UUID: a reconnect starts clean
// (same limitation as error_cooldown.go), and the maps are bounded by the
// same opportunistic >1024 sweep. r.mu discipline and the transition-bool
// return also mirror error_cooldown.go.

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
func (r *Registry) RecordCapacityReject(providerID, modelID string) (tripped bool) {
	if providerID == "" || modelID == "" {
		return false
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	cfg := r.capacityCooldownCfg
	if cfg.Threshold <= 0 {
		return false // disabled via EIGENINFERENCE_CAPACITY_COOLDOWN_THRESHOLD=0
	}
	now := time.Now()

	// Opportunistic sweep (mirrors error_cooldown.go): session provider ids are
	// per-connection UUIDs that never get re-keyed — bound the maps by dropping
	// expired/idle entries once they grow.
	if len(r.capacityCooldowns) > 1024 {
		for key, expiry := range r.capacityCooldowns {
			if !now.Before(expiry) {
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

	key := capacityRejectKey{ProviderID: providerID, ModelID: modelID}

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
	if expiry, ok := r.capacityCooldowns[key]; ok && now.Before(expiry) {
		return false
	}

	trips := r.capacityCooldownTrips[key]
	// A fresh pair (trips == 0) needs the full threshold inside the window. A
	// half-open pair (trips > 0: tripped before, no accept since, cooldown
	// expired → this reject IS the failed re-probe) re-arms immediately.
	if trips == 0 && len(kept) < cfg.Threshold {
		return false
	}

	r.capacityCooldowns[key] = now.Add(capacityCooldownBackoff(cfg, trips))
	r.capacityCooldownTrips[key] = trips + 1
	return true
}

// RecordCapacityAccept records that the (provider, model) pair ACCEPTED work —
// the api layer calls it on the first content-bearing chunk (commit) and on
// clean completion. It clears the pair's reject streak, any active cooldown,
// and the exponential-backoff trip count: an accept proves the pair admits
// work, which is exactly the discriminator that separates a busy-but-serving
// box (must NEVER trip) from a black hole (zero accepts).
func (r *Registry) RecordCapacityAccept(providerID, modelID string) {
	if providerID == "" || modelID == "" {
		return
	}
	key := capacityRejectKey{ProviderID: providerID, ModelID: modelID}
	// Fast path: this runs once per served request, and for a healthy pair all
	// three maps are empty — check under the read lock so the serving hot path
	// does not serialize on r.mu write acquisition.
	r.mu.RLock()
	_, hasStrikes := r.capacityRejectStrikes[key]
	_, hasCooldown := r.capacityCooldowns[key]
	_, hasTrips := r.capacityCooldownTrips[key]
	r.mu.RUnlock()
	if !hasStrikes && !hasCooldown && !hasTrips {
		return
	}
	r.mu.Lock()
	delete(r.capacityRejectStrikes, key)
	delete(r.capacityCooldowns, key)
	delete(r.capacityCooldownTrips, key)
	r.mu.Unlock()
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
// READ-ONLY (no lazy delete) — some callers hold only r.mu.RLock. Caller holds
// r.mu in either mode (mirrors inferenceErrorCooldownActiveLocked). Once now
// reaches the expiry it returns false, letting the next request through as the
// half-open re-probe.
func (r *Registry) capacityCooldownActiveLocked(providerID, modelID string, now time.Time) bool {
	expiry, ok := r.capacityCooldowns[capacityRejectKey{ProviderID: providerID, ModelID: modelID}]
	return ok && now.Before(expiry)
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
