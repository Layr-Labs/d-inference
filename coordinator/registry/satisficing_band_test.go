package registry

import (
	"fmt"
	"math"
	"testing"
	"time"
)

// bandFixture registers three warm gpt-oss boxes with well-separated costs
// (cost gaps >> the 3s near-tie window, so flag-off selection is
// deterministic): fast (decode 100), mid (40), slow (20). With the default
// EIGENINFERENCE_MIN_DECODE_TPS-style floor of 15 all three project above the
// floor at batch 1 (100/1.27, 40/1.27, 20/1.27 = 78.7/31.5/15.7), and with a
// 10s deadline all three TTFT estimates (~0.4s/1.1s/2.1s) clear the band
// margin — so all three are band members.
func bandFixture(t *testing.T, reg *Registry) (fast, mid, slow *Provider) {
	t.Helper()
	fast = makeSchedulerProvider(t, reg, "fast-box", gptossBuild, 100)
	mid = makeSchedulerProvider(t, reg, "mid-box", gptossBuild, 40)
	slow = makeSchedulerProvider(t, reg, "slow-box", gptossBuild, 20)
	return fast, mid, slow
}

func bandRequest(id string) *PendingRequest {
	return &PendingRequest{
		RequestID:             id,
		Model:                 gptossBuild,
		EstimatedPromptTokens: 500,
		RequestedMaxTokens:    2000,
		MaxTTFTMs:             10_000,
		MinDecodeTPS:          15,
	}
}

// reserveOnce runs one production selection and releases the reservation so
// per-trial registry state (pending counts, costs, band membership) is
// identical across trials. Returns the winner's ID.
func reserveOnce(t *testing.T, reg *Registry, pr *PendingRequest) string {
	t.Helper()
	p, _ := reg.ReserveProviderEx(pr.Model, pr)
	if p == nil {
		t.Fatalf("no provider selected for %s", pr.RequestID)
	}
	p.RemovePending(pr.RequestID)
	reg.SetProviderIdle(p.ID)
	return p.ID
}

// TestSatisficingBandOffSelectionPinned is the flag-off contract: with the
// band dormant (the default), selection is byte-for-byte today's cheapest-cost
// path — the fast box wins EVERY trial (its cost is ~30s below the next
// candidate, far outside the near-tie window, so there is no randomization).
func TestSatisficingBandOffSelectionPinned(t *testing.T) {
	t.Setenv(satisficingBandEnv, "false") // pin the default against ambient operator env
	reg := New(testLogger())
	bandFixture(t, reg)
	for i := 0; i < 50; i++ {
		if id := reserveOnce(t, reg, bandRequest(fmt.Sprintf("off-%d", i))); id != "fast-box" {
			t.Fatalf("flag off, trial %d: selected %s, want fast-box every time (deterministic cheapest-cost)", i, id)
		}
	}
}

// TestSatisficingBandSpreadsAcrossMembers: flag on, every band member gets
// selected across repeated trials and the cheapest no longer monopolizes —
// the anti-concentration property the band exists for (top-10% boxes take
// 79% of traffic today). Statistical: with all weights starting at 1 and the
// winner's weight decaying after each serve, P(any member never chosen in 300
// trials) < (2/3)^300 ≈ 10^-53.
func TestSatisficingBandSpreadsAcrossMembers(t *testing.T) {
	t.Setenv(satisficingBandEnv, "true")
	reg := New(testLogger())
	bandFixture(t, reg)

	const trials = 300
	counts := map[string]int{}
	for i := 0; i < trials; i++ {
		counts[reserveOnce(t, reg, bandRequest(fmt.Sprintf("on-%d", i)))]++
	}
	for _, id := range []string{"fast-box", "mid-box", "slow-box"} {
		if counts[id] == 0 {
			t.Fatalf("band member %s never selected across %d trials; counts=%v", id, trials, counts)
		}
	}
	if counts["fast-box"] == trials {
		t.Fatalf("cheapest candidate selected in all %d trials — band selection must not reduce to cheapest-cost; counts=%v", trials, counts)
	}
}

// TestSatisficingBandNonMembersOnlyWhenBandEmpty: candidates outside the band
// are selected ONLY when the band is empty — and then via exactly today's
// cheapest-cost path. All three boxes pass the 3s HARD TTFT gate (~0.7s/1.4s/
// 2.8s estimates) but miss the band boundary (deadline − 2.5s margin = 0.5s),
// so with the flag on the band is empty and the fast box wins deterministically
// (cost gaps >> the near-tie window).
func TestSatisficingBandNonMembersOnlyWhenBandEmpty(t *testing.T) {
	t.Setenv(satisficingBandEnv, "true")
	t.Setenv(satisficingTTFTMarginEnv, "2500")
	reg := New(testLogger())
	makeSchedulerProvider(t, reg, "fast-box", gptossBuild, 60)
	makeSchedulerProvider(t, reg, "mid-box", gptossBuild, 30)
	makeSchedulerProvider(t, reg, "slow-box", gptossBuild, 15)

	pr := func(i int) *PendingRequest {
		return &PendingRequest{
			RequestID:             fmt.Sprintf("empty-band-%d", i),
			Model:                 gptossBuild,
			EstimatedPromptTokens: 500,
			RequestedMaxTokens:    2000,
			MaxTTFTMs:             3_000,
		}
	}
	for i := 0; i < 30; i++ {
		if id := reserveOnce(t, reg, pr(i)); id != "fast-box" {
			t.Fatalf("empty band, trial %d: selected %s, want fast-box (exact cheapest-cost fallback)", i, id)
		}
	}
}

// TestSatisficingBandExcludesColdWhenNoDeadline (review fix): with the default
// soft TTFT mode, public requests carry MaxTTFTMs == 0, so the band has no TTFT
// criterion — without the warm-only restriction, a COLD (slotState "unknown")
// candidate passing the decode floor enters the band and weighted-randomly
// beats the warm provider, forcing avoidable 15–60s model loads. The cold box
// stays reachable via the cheapest-cost fallback only (where statePenalty makes
// it a last resort). Fails without the modelLoaded check in
// candidateInSatisficingBand (the cold box wins ~half of the trials).
func TestSatisficingBandExcludesColdWhenNoDeadline(t *testing.T) {
	t.Setenv(satisficingBandEnv, "true")
	reg := New(testLogger())
	makeSchedulerProvider(t, reg, "warm-box", gptossBuild, 20)
	cold := makeSchedulerProvider(t, reg, "cold-box", gptossBuild, 100)
	// Make the fast box COLD for gpt-oss: advertises it, no backend slot.
	cold.mu.Lock()
	cold.BackendCapacity.Slots = nil
	cold.mu.Unlock()

	for i := 0; i < 100; i++ {
		pr := &PendingRequest{
			RequestID:             fmt.Sprintf("no-deadline-%d", i),
			Model:                 gptossBuild,
			EstimatedPromptTokens: 500,
			RequestedMaxTokens:    2000,
			// Soft TTFT mode: no per-request deadline stamped.
			MaxTTFTMs:    0,
			MinDecodeTPS: 15,
		}
		if id := reserveOnce(t, reg, pr); id != "warm-box" {
			t.Fatalf("trial %d: selected %s, want warm-box — a cold candidate must not enter the band when no deadline exists", i, id)
		}
	}
}

// TestSatisficingBandWeightsShiftWithRecentServes: weight = 1/(1+recentServes).
// A provider seeded with ~9 recent serves (weight ≈ 0.1) is picked ~10× less
// often than never-served peers (weight 1). Expected share 0.1/2.1 ≈ 4.8% of
// 2100 picks ≈ 100; asserting < a quarter of each peer's count puts the
// threshold ~15 standard deviations from the mean.
func TestSatisficingBandWeightsShiftWithRecentServes(t *testing.T) {
	reg := New(testLogger())
	hot := makeSchedulerProvider(t, reg, "hot-box", gptossBuild, 30)
	cold1 := makeSchedulerProvider(t, reg, "cold-1", gptossBuild, 30)
	cold2 := makeSchedulerProvider(t, reg, "cold-2", gptossBuild, 30)
	for i := 0; i < 9; i++ {
		reg.serveCounter.record("hot-box")
	}

	band := []*routingCandidate{{provider: hot}, {provider: cold1}, {provider: cold2}}
	counts := map[string]int{}
	for i := 0; i < 2100; i++ {
		counts[reg.pickSatisficingBandLocked(band).provider.ID]++
	}
	if counts["hot-box"]*4 >= counts["cold-1"] || counts["hot-box"]*4 >= counts["cold-2"] {
		t.Fatalf("recently-served provider not deprioritized: counts=%v (want hot-box ≈ 1/10 of each cold)", counts)
	}
	if counts["hot-box"] == 0 {
		t.Fatalf("recently-served provider fully starved: counts=%v (weights must stay nonzero)", counts)
	}
}

// TestSatisficingBandServeCounterFedOnRealPath: the counter is fed by every
// successful reservation even with the flag OFF, so weights are warm the
// moment the band is enabled.
func TestSatisficingBandServeCounterFedOnRealPath(t *testing.T) {
	t.Setenv(satisficingBandEnv, "false") // recording must be flag-independent
	reg := New(testLogger())
	bandFixture(t, reg)
	winner := reserveOnce(t, reg, bandRequest("feed-1"))
	if got := reg.serveCounter.recentServes(winner); got < 0.99 {
		t.Fatalf("recentServes(%s) = %v after a real reservation, want ~1", winner, got)
	}
}

// TestRecentServeCounterDecay pins the exponential half-life: 2 serves decay
// to ~1 after one half-life and to noise after ten.
func TestRecentServeCounterDecay(t *testing.T) {
	c := newRecentServeCounter()
	base := time.Now()
	now := base
	c.nowFunc = func() time.Time { return now }

	c.record("p")
	c.record("p")
	if got := c.recentServes("p"); got != 2 {
		t.Fatalf("recentServes = %v, want 2 (no decay at t=0)", got)
	}
	now = base.Add(recentServeHalfLife)
	if got := c.recentServes("p"); math.Abs(got-1) > 1e-9 {
		t.Fatalf("recentServes after one half-life = %v, want 1", got)
	}
	now = base.Add(10 * recentServeHalfLife)
	if got := c.recentServes("p"); got >= recentServePruneBelow {
		t.Fatalf("recentServes after ten half-lives = %v, want < %v (decayed to noise)", got, recentServePruneBelow)
	}
	if got := c.recentServes("never-served"); got != 0 {
		t.Fatalf("recentServes(unknown) = %v, want 0", got)
	}
}

// TestSatisficingBandCacheAffinityPinnedWithinBand: an affinity-pinned
// provider that is a band member wins every trial — the prefix-cache TTFT win
// is preserved under the band (a pinned consumer's turns are serial, so the
// pin costs no utilization spread).
func TestSatisficingBandCacheAffinityPinnedWithinBand(t *testing.T) {
	t.Setenv(satisficingBandEnv, "true")
	reg := New(testLogger())
	bandFixture(t, reg)
	reg.RecordCacheAffinity("consumer-1", gptossBuild, "prefix-abc", "mid-box")

	for i := 0; i < 40; i++ {
		pr := bandRequest(fmt.Sprintf("aff-%d", i))
		pr.ConsumerKey = "consumer-1"
		pr.CacheAffinityKey = "prefix-abc"
		if id := reserveOnce(t, reg, pr); id != "mid-box" {
			t.Fatalf("trial %d: selected %s, want the affinity-pinned band member mid-box", i, id)
		}
	}
}
