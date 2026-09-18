package registry

import (
	"fmt"
	"testing"
)

// Fleet replay for the near-tie band.
//
// fleetBandwidthTiers is the REAL memory-bandwidth distribution of the live
// provider fleet, read from the public GET /v1/stats feed on 2026-09-18
// (1,152 providers reporting a bandwidth, 15 distinct tiers).
//
// Bandwidth stands in for decode throughput here because the public feed
// reports decode_tps as 0 for every provider. Decode on a memory-bound model is
// bandwidth-limited, so relative bandwidth is a defensible proxy for RELATIVE
// decode rate — which is all the near-tie comparison depends on. It is a proxy,
// not a measurement, and no absolute tokens/sec claim is made from it.
var fleetBandwidthTiers = []struct {
	gbps  float64
	count int
}{
	{100, 1}, {120, 63}, {150, 5}, {153, 18}, {200, 45},
	{273, 144}, {300, 26}, {307, 68}, {400, 291}, {410, 35},
	{460, 5}, {546, 148}, {614, 94}, {800, 79}, {819, 130},
}

// topTierDecodeTPS anchors the proxy: the fastest tier in the fleet is treated
// as 100 tok/s and every other tier scales linearly with its bandwidth.
const topTierDecodeTPS = 100.0

// buildFleetPool materialises the real fleet as an idle, warm candidate pool for
// one request. Every provider is idle (zero queue, zero pending) and carries no
// derater penalty, which is the below-saturation case under test: the ONLY thing
// separating candidates is the request's own work term.
func buildFleetPool(promptTokens, maxTokens int) []*routingCandidate {
	fastest := 0.0
	for _, tier := range fleetBandwidthTiers {
		if tier.gbps > fastest {
			fastest = tier.gbps
		}
	}
	var pool []*routingCandidate
	for _, tier := range fleetBandwidthTiers {
		decodeTPS := topTierDecodeTPS * tier.gbps / fastest
		prefillTPS := decodeTPS * defaultPrefillToDecodeRatio
		work := float64(promptTokens)/prefillTPS*1000.0 + float64(maxTokens)/decodeTPS*1000.0
		for i := 0; i < tier.count; i++ {
			c := mkWorkCandidate(fmt.Sprintf("%.0f-%d", tier.gbps, i), work, 0, 0, 0)
			pool = append(pool, c)
		}
	}
	return pool
}

// eligibleWinners counts the candidates that could win this pool. Every provider
// is idle, so effectiveQueue and totalPending tie for all of them and the
// selector resolves uniformly at random among the near set — meaning the near
// set IS the set of machines that can ever receive this request.
func eligibleWinners(pool []*routingCandidate) int {
	best := pool[0]
	for _, c := range pool[1:] {
		if c.costMs < best.costMs {
			best = c
		}
	}
	band := nearTieBandMs(best.breakdown.ThisReqMs)
	n := 0
	for _, c := range pool {
		delta := c.costMs - best.costMs
		if delta < 0 {
			delta = -delta
		}
		if delta <= nearTieCostWindowMs || (delta <= band && eligibleForWidenedBand(c)) {
			n++
		}
	}
	return n
}

// TestFleetReplayBandCollapsesOnLongRequests is the replay evidence for the
// starvation claim: against the real fleet distribution, the share of machines
// that can receive a request shrinks as max_tokens grows, because the window is
// absolute while the work term is not.
func TestFleetReplayBandCollapsesOnLongRequests(t *testing.T) {
	withNearTieWindowFraction(t, 0) // upstream behavior

	total := 0
	for _, tier := range fleetBandwidthTiers {
		total += tier.count
	}

	var prev int
	for i, maxTokens := range []int{256, 512, 1024, 4096} {
		eligible := eligibleWinners(buildFleetPool(0, maxTokens))
		t.Logf("max_tokens=%-5d eligible=%4d/%d (%.1f%%)",
			maxTokens, eligible, total, 100*float64(eligible)/float64(total))
		if i > 0 && eligible > prev {
			t.Fatalf("eligible set must not grow with max_tokens: %d -> %d", prev, eligible)
		}
		prev = eligible
	}

	// At a production-representative length the fleet's own incident report
	// records max_tokens averaging 10-21K; even at 4096 the eligible share must
	// already be a small minority, or the starvation mechanism does not hold.
	eligible := eligibleWinners(buildFleetPool(0, 4096))
	if share := float64(eligible) / float64(total); share > 0.25 {
		t.Fatalf("expected the band to collapse to a minority at 4096 tokens, got %.1f%%", 100*share)
	}
}

// TestFleetReplayBandRestoresSpreading is the before/after the spec requires:
// the same fleet, the same request, swept across fractions.
//
// The sweep matters because the fleet's bandwidth tiers are lumpy, so the band
// only changes anything once it is wide enough to reach the next tier down. On
// this distribution a fraction of 0.25 is a NO-OP at 4096 tokens — the gap from
// the 819/800 GB/s tiers to the 614 GB/s tier is ~33% of the leader's work term.
// Any rollout value must be picked against this curve, not guessed.
func TestFleetReplayBandRestoresSpreading(t *testing.T) {
	const maxTokens = 4096

	withNearTieWindowFraction(t, 0)
	before := eligibleWinners(buildFleetPool(0, maxTokens))

	for _, fraction := range []float64{0.1, 0.25, 0.334, 0.5, 0.75, 1.0} {
		SetNearTieCostWindowFraction(fraction)
		after := eligibleWinners(buildFleetPool(0, maxTokens))
		t.Logf("fraction=%-5.3g eligible=%4d  (before=%d)", fraction, after, before)
		if after < before {
			t.Fatalf("the band must never narrow the eligible set: before=%d after=%d", before, after)
		}
	}

	// 0.5 is the smallest swept value that reaches two more hardware tiers on
	// this fleet; pin that it materially widens rather than nudges.
	SetNearTieCostWindowFraction(0.5)
	widened := eligibleWinners(buildFleetPool(0, maxTokens))
	if widened < 2*before {
		t.Fatalf("expected fraction 0.5 to at least double the eligible set: before=%d after=%d",
			before, widened)
	}
}

// TestFleetReplayDeratedProvidersStayExcluded replays the same fleet with a
// derated cohort mixed in and pins that widening never re-admits them.
func TestFleetReplayDeratedProvidersStayExcluded(t *testing.T) {
	withNearTieWindowFraction(t, 0.5)

	pool := buildFleetPool(0, 4096)
	clean := eligibleWinners(pool)

	// Sink every candidate in the pool with a capacity-rate penalty; none may
	// remain eligible through the widened band, only through the absolute one.
	for _, c := range pool {
		c.breakdown.CapacityRateMs = 6_000
	}
	derated := eligibleWinners(pool)

	t.Logf("eligible clean=%d  derated=%d", clean, derated)
	if derated >= clean {
		t.Fatalf("derated candidates must lose widened-band eligibility: clean=%d derated=%d", clean, derated)
	}
}
