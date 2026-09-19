package registry

import (
	"math"
	"testing"
	"time"
)

func newAccountAffinityPolicyCandidate(identity string, ttftMs float64) *routingCandidate {
	return &routingCandidate{
		provider:           &Provider{ID: identity},
		pricedPromptTokens: 100,
		calibrationRatio:   1,
		snapshot: routingSnapshot{
			affinityIdentity:   testAccountAffinityIdentity(identity),
			model:              "model-a",
			modelLoaded:        true,
			slotState:          "idle",
			hasBackendCapacity: true,
			decodeTPS:          100,
			prefillTPS:         1000,
		},
		breakdown: costBreakdown{TTFTMs: ttftMs},
	}
}

func accountAffinityPolicyPair() (*PendingRequest, *routingCandidate, *routingCandidate) {
	pr := &PendingRequest{ConsumerKey: "account-a", Model: "model-a", MinDecodeTPS: 15}
	a := newAccountAffinityPolicyCandidate("serial:a", 1000)
	b := newAccountAffinityPolicyCandidate("serial:b", 1000)
	a.accountAffinityScore = accountAffinityScore(pr.ConsumerKey, pr.Model, a.snapshot.affinityIdentity)
	b.accountAffinityScore = accountAffinityScore(pr.ConsumerKey, pr.Model, b.snapshot.affinityIdentity)
	if accountAffinityCandidateBefore(b, a) {
		a, b = b, a
	}
	return pr, a, b
}

func TestAccountAffinityLoadDelayAndStableSpill(t *testing.T) {
	for _, tc := range []struct {
		name    string
		premium float64
		added   float64
		spill   bool
	}{
		{"at 250ms boundary", 250, 250, false},
		{"over 250ms boundary", 250, 250.01, true},
		{"zero allowance idle", 0, 0, false},
		{"zero allowance queued work", 0, 0.01, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			pr, preferred, next := accountAffinityPolicyPair()
			// Isolate queued-prefill time at 1000 tok/s. Unlike the old
			// policy, a peer's intrinsic speed is not a load baseline.
			preferred.snapshot.pendingPrefillKnown = true
			preferred.snapshot.pendingPrefillTokens = tc.added
			preferred.breakdown.TTFTMs = 2000 + tc.added
			preferred.costMs, next.costMs = 999999, 1 // Not the affinity latency metric.
			cfg := AccountAffinityConfig{Mode: AccountAffinityOn, MaxTTFTPenaltyMs: tc.premium}
			winner, observation := evaluateAccountAffinity([]*routingCandidate{next, preferred}, pr, cfg)
			want, rank, reason := preferred, 1, "preferred"
			if tc.spill {
				want, rank, reason = next, 2, "spill"
			}
			if winner != want || observation.Rank != rank || observation.Reason != reason || observation.CandidateCount != 2 {
				t.Fatalf("unexpected winner/observation: %+v", observation)
			}
			if math.Abs(observation.AddedTTFTMs-accountAffinityLoadDelayMs(want)) > 1e-9 {
				t.Fatalf("incorrect load penalty: %+v", observation)
			}
			if observation.Applied || observation.WouldChange {
				t.Fatal("policy invented a legacy comparison")
			}
			// Once pressure clears, placement returns to the same rank without
			// remembering prior spill destinations or rehashing against load.
			preferred.snapshot.pendingPrefillTokens = 0
			preferred.breakdown.TTFTMs = 2000
			winner, _ = evaluateAccountAffinity([]*routingCandidate{preferred, next}, pr, cfg)
			if winner != preferred {
				t.Fatal("clearing pressure changed deterministic preference")
			}
		})
	}
}

func TestAccountAffinityUsesImmediateOccupancyForDecodeFloor(t *testing.T) {
	pr, preferred, next := accountAffinityPolicyPair()
	preferred.snapshot.decodeTPS = 40
	preferred.snapshot.pendingForModel = 8
	preferred.snapshot.backendRunning = 0
	if projectedPerRequestDecodeTPS(&preferred.snapshot) < pr.MinDecodeTPS {
		t.Fatal("fixture heartbeat alone should appear fast enough")
	}
	before := preferred.accountAffinityScore
	winner, observation := evaluateAccountAffinity([]*routingCandidate{preferred, next}, pr, AccountAffinityConfig{Mode: AccountAffinityOn, MaxTTFTPenaltyMs: 250})
	if winner != next || observation.Reason != "spill" || preferred.accountAffinityEligible {
		t.Fatal("unreflected reservations did not trigger affinity spill")
	}
	if preferred.accountAffinityScore != before {
		t.Fatal("load modified affinity rank")
	}
	// With no requested floor, do not invent a new global quality rejection.
	pr.MinDecodeTPS = 0
	winner, _ = evaluateAccountAffinity([]*routingCandidate{preferred, next}, pr, AccountAffinityConfig{Mode: AccountAffinityOn, MaxTTFTPenaltyMs: 2000})
	if winner != preferred {
		t.Fatal("absent request floor was tightened")
	}
}

func TestAccountAffinityCoResidentLoadSpillsWithoutDoubleCounting(t *testing.T) {
	for _, backendReported := range []bool{false, true} {
		pr, preferred, next := accountAffinityPolicyPair()
		preferred.snapshot.decodeTPS = 40
		if backendReported {
			preferred.snapshot.affinityBackendOccupancy = 8
		} else {
			preferred.snapshot.totalPending = 8
		}
		if snapshotOccupancy(&preferred.snapshot) != 0 {
			t.Fatal("fixture should have no target-model occupancy")
		}
		cfg := AccountAffinityConfig{Mode: AccountAffinityOn, MaxTTFTPenaltyMs: 250}
		winner, _ := evaluateAccountAffinity([]*routingCandidate{preferred, next}, pr, cfg)
		if winner != next {
			t.Fatalf("backendReported=%v: other-model GPU work did not trigger spill", backendReported)
		}
		next.snapshot = preferred.snapshot
		next.snapshot.affinityIdentity = testAccountAffinityIdentity("serial:other")
		if winner, _ := evaluateAccountAffinity([]*routingCandidate{preferred, next}, pr, cfg); winner != nil {
			t.Fatal("all below-floor candidates must fall back to ordinary selection")
		}
	}
	snapshot := routingSnapshot{pendingForModel: 3, totalPending: 5, backendRunning: 2, backendWaiting: 1, affinityBackendOccupancy: 5}
	if got := accountAffinityOccupancy(&snapshot); got != 5 {
		t.Fatalf("coordinator and backend work double-counted: got %d, want5", got)
	}
}

func TestAccountAffinityDeadlineDoesNotResetAcrossFallbacks(t *testing.T) {
	for _, tc := range []struct {
		name      string
		remaining time.Duration
		maxTTFT   float64
		wantNext  bool
		wantNone  bool
	}{
		{"fits", 1300 * time.Millisecond, 0, false, false},
		{"absolute deadline spill", 1100 * time.Millisecond, 0, true, false},
		{"request ceiling spill", 3 * time.Second, 1100, true, false},
		{"nothing fits", 500 * time.Millisecond, 0, false, true},
		{"expired", -time.Millisecond, 0, false, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			pr, preferred, next := accountAffinityPolicyPair()
			now := time.Unix(1000, 0)
			pr.FirstContentDeadline = now.Add(tc.remaining)
			pr.FirstContentBudgetMS = 99999 // A stale wire budget is not the deadline.
			pr.MaxTTFTMs = tc.maxTTFT
			preferred.breakdown.TTFTMs = 1200
			winner, _ := evaluateAccountAffinityAt([]*routingCandidate{preferred, next}, pr, AccountAffinityConfig{Mode: AccountAffinityOn, MaxTTFTPenaltyMs: 250}, now)
			want := preferred
			if tc.wantNext {
				want = next
			}
			if tc.wantNone {
				want = nil
			}
			if winner != want {
				t.Fatal("affinity did not preserve actual request deadline")
			}
			if pr.FirstContentDeadline != now.Add(tc.remaining) || pr.FirstContentBudgetMS != 99999 {
				t.Fatal("affinity mutated the request clock")
			}
		})
	}
}

func TestAccountAffinityShadowMatchesOnAndUnsupportedFallsBack(t *testing.T) {
	pr, preferred, next := accountAffinityPolicyPair()
	pool := []*routingCandidate{next, preferred}
	on, onObs := evaluateAccountAffinity(pool, pr, AccountAffinityConfig{Mode: AccountAffinityOn, MaxTTFTPenaltyMs: 250})
	shadow, shadowObs := evaluateAccountAffinity(pool, pr, AccountAffinityConfig{Mode: AccountAffinityShadow, MaxTTFTPenaltyMs: 250})
	if on != shadow || onObs.Rank != shadowObs.Rank || onObs.AddedTTFTMs != shadowObs.AddedTTFTMs || shadowObs.Applied {
		t.Fatal("shadow and on evaluated differently")
	}
	for _, tc := range []struct {
		name   string
		modify func(*PendingRequest, *AccountAffinityConfig)
		reason string
	}{
		{"off", func(_ *PendingRequest, c *AccountAffinityConfig) { c.Mode = AccountAffinityOff }, "off"},
		{"zero config", func(_ *PendingRequest, c *AccountAffinityConfig) { *c = AccountAffinityConfig{} }, "off"},
		{"invalid mode", func(_ *PendingRequest, c *AccountAffinityConfig) { c.Mode = "typo" }, "invalid_config"},
		{"missing account", func(p *PendingRequest, _ *AccountAffinityConfig) { p.ConsumerKey = "" }, "missing_account"},
		{"missing model", func(p *PendingRequest, _ *AccountAffinityConfig) { p.Model = "" }, "missing_model"},
		{"vision", func(p *PendingRequest, _ *AccountAffinityConfig) { p.RequiresVision = true }, "vision"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			request := &PendingRequest{ConsumerKey: pr.ConsumerKey, Model: pr.Model}
			cfg := AccountAffinityConfig{Mode: AccountAffinityOn, MaxTTFTPenaltyMs: 250}
			tc.modify(request, &cfg)
			candidate := newAccountAffinityPolicyCandidate("serial:c", 1000)
			winner, observation := evaluateAccountAffinity([]*routingCandidate{candidate}, request, cfg)
			if winner != nil || observation.Reason != tc.reason || observation.Evaluated || candidate.accountAffinityRanked {
				t.Fatalf("unsupported path didn't fall back without hashing: %+v", observation)
			}
		})
	}
}

func TestAccountAffinityUnreliableOrDegradedCandidatesStayOnLegacyPath(t *testing.T) {
	for _, tc := range []struct {
		name   string
		modify func(*routingCandidate)
	}{
		{"no identity", func(c *routingCandidate) { c.snapshot.affinityIdentity = accountAffinityIdentity{} }},
		{"unknown backend", func(c *routingCandidate) { c.snapshot.hasBackendCapacity = false }},
		{"not resident", func(c *routingCandidate) { c.snapshot.modelLoaded = false }},
		{"cold state", func(c *routingCandidate) { c.snapshot.slotState = "unknown" }},
		{"NaN TTFT", func(c *routingCandidate) { c.breakdown.TTFTMs = math.NaN() }},
		{"infinite TTFT", func(c *routingCandidate) { c.breakdown.TTFTMs = math.Inf(1) }},
		{"zero TTFT", func(c *routingCandidate) { c.breakdown.TTFTMs = 0 }},
		{"negative TTFT", func(c *routingCandidate) { c.breakdown.TTFTMs = -1 }},
		{"below decode floor", func(c *routingCandidate) { c.snapshot.decodeTPS = 1 }},
		{"capacity rejects", func(c *routingCandidate) { c.breakdown.CapacityRateMs = 5000 }},
		{"thermal fair", func(c *routingCandidate) { c.snapshot.systemMetrics.ThermalState = "fair" }},
		{"thermal serious", func(c *routingCandidate) { c.snapshot.systemMetrics.ThermalState = "serious" }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			pr, preferred, next := accountAffinityPolicyPair()
			tc.modify(preferred)
			cfg := AccountAffinityConfig{Mode: AccountAffinityOn, MaxTTFTPenaltyMs: 250}
			winner, _ := evaluateAccountAffinity([]*routingCandidate{preferred, next}, pr, cfg)
			if winner != next || preferred.accountAffinityEligible {
				t.Fatal("unreliable/degraded candidate received affinity")
			}
			winner, _ = evaluateAccountAffinity([]*routingCandidate{preferred}, pr, cfg)
			if winner != nil {
				t.Fatal("absence of a quality candidate should use legacy selection")
			}
		})
	}
}

func TestAccountAffinityIntrinsicSpeedDoesNotTriggerSpill(t *testing.T) {
	pr, preferred, next := accountAffinityPolicyPair()
	preferred.breakdown.TTFTMs = 900
	next.breakdown.TTFTMs = 400
	// Make the same-machine estimate consistent with the actual request,
	// including the projected first decode for an otherwise idle provider.
	preferred.snapshot.prefillTPS = 100_000 / (900 - 13.9)
	next.snapshot.prefillTPS = 100_000 / (400 - 13.9)
	for _, allowance := range []float64{0, 250} {
		winner, observation := evaluateAccountAffinity([]*routingCandidate{next, preferred}, pr,
			AccountAffinityConfig{Mode: AccountAffinityOn, MaxTTFTPenaltyMs: allowance})
		if winner != preferred || observation.Rank != 1 || observation.AddedTTFTMs != 0 {
			t.Fatalf("idle 900ms home displaced by 400ms peer: %+v", observation)
		}
	}
	// Adding or speeding up an otherwise suitable lower-ranked peer cannot
	// alter whether this idle home is considered busy.
	next.breakdown.TTFTMs = 40
	next.snapshot.prefillTPS = 100_000 / (40 - 13.9)
	next.snapshot.affinityIdentity = accountAffinityIdentity{}
	winner, _ := evaluateAccountAffinity([]*routingCandidate{preferred, next}, pr,
		AccountAffinityConfig{Mode: AccountAffinityOn, MaxTTFTPenaltyMs: 250})
	if winner != preferred {
		t.Fatal("faster unidentified peer changed the home's busy decision")
	}
}

func TestAccountAffinityLoadDelayDoesNotSubtractCacheCredit(t *testing.T) {
	pr, preferred, next := accountAffinityPolicyPair()
	preferred.snapshot.pendingPrefillKnown = true
	preferred.snapshot.pendingPrefillTokens = 300
	preferred.breakdown.CacheDiscountMs = 10000
	preferred.cacheEstimatedTTFTSavedMs = 10000
	next.snapshot.affinityIdentity = accountAffinityIdentity{}
	winner, observation := evaluateAccountAffinity([]*routingCandidate{preferred, next}, pr, AccountAffinityConfig{Mode: AccountAffinityOn, MaxTTFTPenaltyMs: 250})
	if winner != nil || observation.Reason != "no_eligible_candidate" {
		t.Fatal("cache credit erased actual queued-prefill delay")
	}
	preferred.snapshot.pendingPrefillTokens = 0
	next.snapshot.decodeTPS = 1
	preferred.breakdown.HealthMs = 2500 // Normal resident memory/CPU health cost.
	winner, observation = evaluateAccountAffinity([]*routingCandidate{preferred, next}, pr, AccountAffinityConfig{Mode: AccountAffinityOn, MaxTTFTPenaltyMs: 0})
	if winner != preferred || observation.AddedTTFTMs != 0 {
		t.Fatal("idle home displaced by a below-floor peer or normal memory cost")
	}
}
