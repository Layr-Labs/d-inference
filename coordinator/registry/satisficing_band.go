package registry

import (
	"math"
	"math/rand"
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/env"
)

// Satisficing utilization band — activate the idle 70% (plan §2.8).
//
// Candidate selection today is strictly cheapest-cost with near-tie
// randomization, so the fastest boxes win everything: the top-10% of boxes
// take 79% of traffic, the median gpt-oss box serves 9 requests/day, ~70% of
// online boxes serve nothing in a given hour, and 41 online 24GB boxes
// advertising gpt-oss served 0 — while their solo 19 tok/s decode comfortably
// clears the 15 tok/s quality floor. Consumers don't experience "cheapest
// cost"; they experience "met the SLO or not". So among candidates PREDICTED
// to meet the SLO (the band), selection becomes weighted-random with an
// inverse-recent-serves weight instead of cost-ranked — spreading traffic
// across every box that would satisfy the consumer, favoring the ones that
// served least recently.
//
// Band membership reuses the EXACT predicates admission already computes — no
// new estimators:
//
//   - predicted TTFT: the candidate's calibrated breakdown.TTFTMs — the same
//     value the hard TTFT ceiling (pr.MaxTTFTMs) gates on — must clear the
//     deadline minus EIGENINFERENCE_SATISFICING_TTFT_MARGIN_MS (default
//     1000ms; the margin buys prediction error). Candidates without
//     BackendCapacity have no reliable TTFT estimate and are excluded from
//     the band when a deadline exists (they stay selectable via the
//     cheapest-cost fallback, exactly as today). Requests without a deadline
//     (pr.MaxTTFTMs <= 0, e.g. soft-gate mode or queue drains) satisfy the
//     TTFT criterion vacuously.
//   - predicted decode: projectedPerRequestDecodeTPS(snapshot) >=
//     pr.MinDecodeTPS — the same projection the decode-floor quality
//     preference uses. Vacuous when no floor is stamped.
//
// Selection within the band is weighted random, weight = 1/(1+recentServes),
// where recentServes is a registry-local in-memory exponentially-decaying
// per-provider serve counter (half-life 5 minutes ≈ the "sliding ~10-minute
// window" shape; chosen over a bucketed window for simplicity and exact
// testability — decay is a pure function of elapsed time). The counter is fed
// on EVERY successful reservation regardless of the flag, so weights are
// already warm when the flag flips on; it is restart-wiped like the TPS
// registries (acceptable: it converges within minutes).
//
// Cache affinity keeps its pin WITHIN the band: if the affinity provider is a
// band member it wins, preserving prefix-cache TTFT for repeat-prefix
// consumers (their turns are serial, so pinning them costs no utilization
// spread; evicting them from their cached box would regress TTFT p90 — the
// rollout guard metric).
//
// Everything else is unchanged: candidates OUTSIDE the band never displace
// the cheapest-cost path (when the band is empty — or the flag is off, the
// default — selection is byte-for-byte today's), and speculative/backup
// dispatch, queueing, retries, and admission gates are untouched. The band
// only reorders WHICH eligible candidate is picked first.

const (
	satisficingBandEnv       = env.EnvPrefix + "_SATISFICING_BAND"
	satisficingTTFTMarginEnv = env.EnvPrefix + "_SATISFICING_TTFT_MARGIN_MS"
)

// defaultSatisficingTTFTMarginMs is the TTFT safety margin (ms) subtracted
// from the request deadline for band membership when
// EIGENINFERENCE_SATISFICING_TTFT_MARGIN_MS is unset.
const defaultSatisficingTTFTMarginMs = 1000.0

// satisficingBandEnabled gates the whole feature. Read LIVE (no restart,
// mirroring decodeFloorUseFleetMedian); default FALSE — dormant until the
// staged canary after gemma re-enable stabilizes.
func satisficingBandEnabled() bool {
	return env.EnvBool(satisficingBandEnv, false)
}

// satisficingTTFTMarginMs returns the band's TTFT safety margin. Read live;
// negative values are clamped to 0 (band boundary = the raw deadline).
func satisficingTTFTMarginMs() float64 {
	m := env.EnvFloat(satisficingTTFTMarginEnv, defaultSatisficingTTFTMarginMs)
	if m < 0 || math.IsNaN(m) {
		m = 0
	}
	return m
}

// candidateInSatisficingBand reports whether a cost-eligible candidate is
// predicted to satisfy the request's SLO with margin to spare. It reuses the
// candidate's already-computed gate inputs — breakdown.TTFTMs (the calibrated
// estimate the hard MaxTTFTMs ceiling consumes) and
// projectedPerRequestDecodeTPS (the decode-floor preference's projection) —
// so band membership can never disagree with admission about what "fast
// enough" means.
func candidateInSatisficingBand(c *routingCandidate, pr *PendingRequest, marginMs float64) bool {
	if c == nil {
		return false
	}
	if pr.MaxTTFTMs > 0 {
		// A deadline exists: require a RELIABLE estimate that clears it with
		// margin. No BackendCapacity means no reliable TTFT estimate — not a
		// band member (still reachable via the cheapest-cost fallback).
		if !c.snapshot.hasBackendCapacity {
			return false
		}
		if c.breakdown.TTFTMs > pr.MaxTTFTMs-marginMs {
			return false
		}
	}
	if pr.MinDecodeTPS > 0 && projectedPerRequestDecodeTPS(c.snapshot) < pr.MinDecodeTPS {
		return false
	}
	return true
}

// satisficingBandMembers filters the eligible pool down to band members.
func satisficingBandMembers(pool []*routingCandidate, pr *PendingRequest) []*routingCandidate {
	marginMs := satisficingTTFTMarginMs()
	band := make([]*routingCandidate, 0, len(pool))
	for _, c := range pool {
		if candidateInSatisficingBand(c, pr, marginMs) {
			band = append(band, c)
		}
	}
	return band
}

// pickSatisficingBandLocked selects a band member by weighted random with
// weight = 1/(1+recentServes). A provider that just served a burst decays
// toward weight 1 within a few half-lives; a box that served nothing holds
// weight 1 — so the idle majority absorbs new load first while every member
// keeps a nonzero chance (no starvation, no hard round-robin). Caller holds
// r.mu (band candidates borrow registry state); the serve counter has its own
// lock.
func (r *Registry) pickSatisficingBandLocked(band []*routingCandidate) *routingCandidate {
	if len(band) == 0 {
		return nil
	}
	if len(band) == 1 {
		return band[0]
	}
	weights := make([]float64, len(band))
	total := 0.0
	for i, c := range band {
		w := 1.0 / (1.0 + r.serveCounter.recentServes(c.provider.ID))
		weights[i] = w
		total += w
	}
	x := rand.Float64() * total
	for i, c := range band {
		x -= weights[i]
		if x < 0 {
			return c
		}
	}
	return band[len(band)-1] // float underflow backstop
}

// --- Recent-serve counter ---

const (
	// recentServeHalfLife is the exponential-decay half-life of the serve
	// counter: a serve contributes 1.0 immediately, 0.5 after 5 minutes, ~0.25
	// after 10 — approximating a sliding ~10-minute window of "how much has
	// this box served lately" with O(1) state per provider.
	recentServeHalfLife = 5 * time.Minute
	// recentServePruneBelow: entries decayed to negligible weight-impact are
	// pruned opportunistically (weight 1/(1+0.01) ≈ 0.99, indistinguishable
	// from never-served).
	recentServePruneBelow = 0.01
	// recentServePruneScanThreshold bounds map growth on long-lived
	// registries with heavy session-ID churn: once the map exceeds this size,
	// each record() sweeps out decayed entries.
	recentServePruneScanThreshold = 4096
)

// recentServeCounter is the registry-local decaying per-provider serve
// counter behind the band's inverse-recent-serves weight. Keyed by provider
// session ID (a reconnect starts fresh at weight 1 — acceptable: the counter
// is a fairness heuristic, not an accounting ledger). nowFunc is injectable
// for deterministic decay tests.
type recentServeCounter struct {
	mu      sync.Mutex
	nowFunc func() time.Time
	entries map[string]*recentServeEntry
}

type recentServeEntry struct {
	count float64   // decayed serve count as of last
	last  time.Time // when count was last materialized
}

func newRecentServeCounter() *recentServeCounter {
	return &recentServeCounter{
		nowFunc: time.Now,
		entries: make(map[string]*recentServeEntry),
	}
}

// decayedLocked returns e's count decayed to now. Caller holds c.mu.
func decayedLocked(e *recentServeEntry, now time.Time) float64 {
	dt := now.Sub(e.last)
	if dt <= 0 {
		return e.count
	}
	return e.count * math.Exp2(-float64(dt)/float64(recentServeHalfLife))
}

// record adds one serve for the provider (called on every successful
// reservation — flag-independent so the weights are warm when the band is
// enabled).
func (c *recentServeCounter) record(providerID string) {
	if c == nil || providerID == "" {
		return
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	now := c.nowFunc()
	if e, ok := c.entries[providerID]; ok {
		e.count = decayedLocked(e, now) + 1
		e.last = now
	} else {
		c.entries[providerID] = &recentServeEntry{count: 1, last: now}
	}
	if len(c.entries) > recentServePruneScanThreshold {
		for id, e := range c.entries {
			if id == providerID {
				continue
			}
			if decayedLocked(e, now) < recentServePruneBelow {
				delete(c.entries, id)
			}
		}
	}
}

// recentServes returns the provider's decayed serve count (0 for unknown
// providers).
func (c *recentServeCounter) recentServes(providerID string) float64 {
	if c == nil {
		return 0
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	e, ok := c.entries[providerID]
	if !ok {
		return 0
	}
	return decayedLocked(e, c.nowFunc())
}
