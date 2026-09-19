package registry

import (
	"math"
	"testing"
	"time"
)

func TestAccountAffinityLoadEstimateUsesOwnRatesAndCalibration(t *testing.T) {
	c := newAccountAffinityPolicyCandidate("serial:home", 210)
	c.snapshot.backendWaiting = 1
	c.calibrationRatio = 1.25
	c.breakdown.TTFTMs = 210 * c.calibrationRatio
	delay, loaded := accountAffinityLoadEstimate(c)
	// Own 100ms prefill cancels. The queue adds 100ms and another request
	// adds 3.9ms to first decode (17.8ms versus idle's 13.9ms).
	if math.Abs(delay-103.9*1.25) > 1e-9 || math.Abs(loaded-217.8*1.25) > 1e-9 {
		t.Fatalf("load estimate=(%f,%f), want(%f,%f)", delay, loaded, 103.9*1.25, 217.8*1.25)
	}
	// Max-output/KV reservations aren't serial decode work ahead of first
	// token. Changing them cannot manufacture a load-induced waiting time.
	c.snapshot.pendingMaxTokens = 1_000_000
	c.snapshot.activeTokenBudgetUsed = 1_000_000
	c.snapshot.queuedTokenBudget = 1_000_000
	if after, _ := accountAffinityLoadEstimate(c); after != delay {
		t.Fatal("output-token reservations were counted as queued inference time")
	}
}

func TestAccountAffinityDeadlineCountsQueuedPrefillOnce(t *testing.T) {
	c := newAccountAffinityPolicyCandidate("serial:home", 210)
	c.snapshot.backendWaiting = 1
	pr := &PendingRequest{ConsumerKey: "account", Model: "model-a", MaxTTFTMs: 220}
	cfg := AccountAffinityConfig{Mode: AccountAffinityOn, MaxTTFTPenaltyMs: 250}
	if !accountAffinityFeasible(c, pr, cfg) {
		t.Fatal("queued prefill was added twice to the full TTFT deadline check")
	}
	pr.MaxTTFTMs = 215 // Live210ms fits, but joining this batch predicts217.8ms.
	if accountAffinityFeasible(c, pr, cfg) {
		t.Fatal("ignored load-aware full first-token estimate at deadline")
	}
	pr.MaxTTFTMs = 0
	pr.FirstContentDeadline = time.Unix(1000, 0).Add(215 * time.Millisecond)
	if accountAffinityFeasibleAt(c, pr, cfg, time.Unix(1000, 0)) {
		t.Fatal("absolute first-content budget ignored")
	}
}

func TestAccountAffinityDecodeLoadUnwindsObservedBatch(t *testing.T) {
	c := newAccountAffinityPolicyCandidate("serial:home", 110)
	c.snapshot.backendRunning = 2
	c.snapshot.observedDecodeTPS = 50
	c.snapshot.totalPending = 4
	// Observation50 at B2 implies solo89. Existing whole-box work is4,
	// not2+4. The added first-token delay is k*4/89 seconds.
	delay, _ := accountAffinityLoadEstimate(c)
	want := 1000 * effectiveTPSLoadFactor * 4 / (50 * (1 + effectiveTPSLoadFactor*2))
	if math.Abs(delay-want) > 1e-9 {
		t.Fatalf("wrong observed-rate unwind or double-counted occupancy: %f want%f", delay, want)
	}
}

func TestAccountAffinityUnknownLoadEstimateFallsBack(t *testing.T) {
	for _, tc := range []struct {
		name   string
		change func(*routingCandidate)
	}{
		{"zero calibration", func(c *routingCandidate) { c.calibrationRatio = 0 }},
		{"NaN calibration", func(c *routingCandidate) { c.calibrationRatio = math.NaN() }},
		{"infinite calibration", func(c *routingCandidate) { c.calibrationRatio = math.Inf(1) }},
		{"missing prefill rate", func(c *routingCandidate) { c.snapshot.prefillTPS = 0 }},
		{"NaN prefill rate", func(c *routingCandidate) { c.snapshot.prefillTPS = math.NaN() }},
		{"missing decode rate", func(c *routingCandidate) { c.snapshot.decodeTPS = 0 }},
		{"invalid queued work", func(c *routingCandidate) {
			c.snapshot.pendingPrefillKnown = true
			c.snapshot.pendingPrefillTokens = math.NaN()
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			pr, home, next := accountAffinityPolicyPair()
			tc.change(home)
			if delay, _ := accountAffinityLoadEstimate(home); !math.IsInf(delay, 1) {
				t.Fatalf("invalid input produced usable delay: %f", delay)
			}
			winner, _ := evaluateAccountAffinity([]*routingCandidate{home, next}, pr,
				AccountAffinityConfig{Mode: AccountAffinityOn, MaxTTFTPenaltyMs: 250})
			if winner != next {
				t.Fatal("invalid estimate received preference")
			}
		})
	}
}
