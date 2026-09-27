package registry

import (
	"fmt"
	"math"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// creditTestFixture prices real checkpoint evidence through the production
// scan and commit path. Every provider prefills at 1,000 tok/s and decodes at
// 100 tok/s, so a 4,352-token prompt with 128 output tokens costs 4,352 +
// 1,280 + 550 (health) = 6,182 ms cold, and a fresh 4,096-token checkpoint
// with a 100 ms stage is a 3,996 ms credit. One same-model pending turn with
// prompt P adds 3,000 (queue) + 750 (pending) + (P + 128) / 100 tok/s of
// backlog to the holder.
type creditTestFixture struct {
	r                 *Registry
	capability        protocol.PrefixCacheV2Capability
	plan              CachePlan
	checkpoint, floor protocol.PrefixCacheAnchor
}

func newCreditTestFixture(t *testing.T) creditTestFixture {
	t.Helper()
	r, _, _ := exactTestRegistry(t)
	removeTestProvider(r, "provider-a")
	r.cacheRoutingMaxDiscountMs, r.cacheRoutingMaxCostFraction = nil, nil
	checkpoint, floor := exactTestAnchor(16, "c"), exactTestAnchor(17, "d")
	return creditTestFixture{r: r, capability: indexTestCapability(1),
		plan: boundTestCachePlan(r, exactTestPlan(checkpoint, floor)), checkpoint: checkpoint, floor: floor}
}

func setTestProviderRates(p *Provider, prefillTPS, decodeTPS float64) {
	p.mu.Lock()
	p.PrefillTPS = prefillTPS
	p.BackendCapacity.Slots[0].ObservedPrefillTPS = prefillTPS
	p.BackendCapacity.Slots[0].ObservedDecodeTPS = decodeTPS
	p.mu.Unlock()
}

// holder registers a cache-capable provider; publish gives it durable evidence.
func (f creditTestFixture) holder(t *testing.T, id string) *Provider {
	t.Helper()
	p := checkpointTestProvider(t, f.r, id, f.capability)
	setTestProviderRates(p, 1000, 100)
	return p
}

func (f creditTestFixture) cold(t *testing.T, id string) *Provider {
	t.Helper()
	p := makeSchedulerProvider(t, f.r, id, "model", 100)
	setTestProviderRates(p, 1000, 100)
	return p
}

func (f creditTestFixture) publish(t *testing.T, p *Provider, donor string, anchor protocol.PrefixCacheAnchor, stageMs float64) {
	t.Helper()
	_, ready := checkpointTestAttempt(t, f.r, p, f.capability, donor, f.plan, 1)
	ready.ReadyAnchors = []protocol.PrefixCacheAnchor{anchor}
	ready.ExpectedPrefillTokensSaved, ready.StageMs = anchor.TokenCount, stageMs
	if !f.r.ApplyPrefixCacheReadyV2(p.ID, ready) {
		t.Fatalf("durable checkpoint receipt for %s rejected", p.ID)
	}
}

func (f creditTestFixture) pendingTurn(p *Provider, id, model string, prompt int) {
	p.AddPending(&PendingRequest{RequestID: id, Model: model, EstimatedPromptTokens: prompt, RequestedMaxTokens: 128})
}

func (f creditTestFixture) request(id string) *PendingRequest {
	return &PendingRequest{RequestID: id, Model: "model", CachePlan: f.plan,
		EstimatedPromptTokens: f.plan.PromptTokenCount, RequestedMaxTokens: 128}
}

// reserve routes one request and releases the reservation, returning the
// decision and the request's terminal cache diagnostics.
func (f creditTestFixture) reserve(t *testing.T, id string) (*Provider, RoutingDecision, *PendingRequest) {
	t.Helper()
	pr := f.request(id)
	p, decision := f.r.ReserveProviderEx("model", pr)
	if p == nil {
		t.Fatalf("no provider reserved: %+v", decision)
	}
	p.RemovePending(pr.RequestID)
	f.r.SetProviderIdle(p.ID)
	return p, decision, pr
}

func TestCacheCreditWinsInsideNearTieBandAgainstPendingTurn(t *testing.T) {
	for _, tc := range []struct {
		name          string
		pendingPrompt int
		want          string
		nearTie       int
		path          SelectionPath
		reason        string
		minAbove      float64
		maxAbove      float64
	}{
		// 3,000 + 750 + 2,280 of pending-turn penalties against a 3,996 credit:
		// the holder is ~2,034 ms above the idle cold peer and still wins.
		{name: "two_seconds_above_wins", pendingPrompt: 100, want: "holder", nearTie: 2,
			path: SelectionCacheCredit, reason: "selected_near_tie", minAbove: 1500, maxAbove: 3000},
		// 4,280 of backlog instead: ~4,034 ms above, beyond the band; it loses.
		{name: "four_seconds_above_loses", pendingPrompt: 300, want: "cold", nearTie: 1,
			path: SelectionUniqueMin, reason: "holder_not_selected", minAbove: 3000, maxAbove: 5000},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := newCreditTestFixture(t)
			holder, cold := f.holder(t, "holder"), f.cold(t, "cold")
			f.publish(t, holder, "donor", f.checkpoint, 100)
			f.pendingTurn(holder, "previous-turn", "model", tc.pendingPrompt)
			for round := range 3 {
				selected, decision, pr := f.reserve(t, fmt.Sprintf("repeat-%d", round))
				if selected.ID != tc.want || decision.NearTiePoolSize != tc.nearTie || decision.SelectionPath != tc.path {
					t.Fatalf("round %d selected %s near=%d path=%s, want %s/%d/%s: %+v", round,
						selected.ID, decision.NearTiePoolSize, decision.SelectionPath, tc.want, tc.nearTie, tc.path, decision)
				}
				holderCost, coldCost := decision.CostMs, decision.RunnerUp.CostMs
				if selected == cold {
					holderCost, coldCost = decision.RunnerUp.CostMs, decision.CostMs
				}
				if above := holderCost - coldCost; above < tc.minAbove || above > tc.maxAbove {
					t.Fatalf("holder is %.0f ms above the cold peer, want [%.0f, %.0f]: %+v", above, tc.minAbove, tc.maxAbove, decision)
				}
				if got := pr.CacheOpportunityReason(); got != tc.reason || pr.CacheOpportunity.CreditedCandidates != 1 {
					t.Fatalf("reason=%s want=%s: %+v", got, tc.reason, pr.CacheOpportunity)
				}
				if selected == holder {
					if decision.QueueMs != queueDepthPenaltyMs || decision.PendingMs != totalPendingPenaltyMs ||
						decision.BacklogMs <= 0 || decision.CacheDiscountMs <= 0 || !pr.CacheSelectionSelected ||
						!pr.CacheOpportunity.CreditWonNearTie {
						t.Fatalf("credit did not leave the pending-turn penalties intact: %+v", decision)
					}
				} else if decision.CacheDiscountMs != 0 || decision.CacheTier != "" || pr.CacheSelectionSelected ||
					pr.CacheOpportunity.CreditWonNearTie {
					t.Fatalf("cold peer inherited holder accounting: %+v", decision)
				}
			}
		})
	}
}

func TestCacheCreditRanksHoldersByAdjustedCost(t *testing.T) {
	f := newCreditTestFixture(t)
	longer := exactTestAnchor(20, "e")
	f.plan = boundTestCachePlan(f.r, exactTestPlan(f.checkpoint, longer, exactTestAnchor(21, "f")))
	long, short := f.holder(t, "long"), f.holder(t, "short")
	f.cold(t, "cold")
	f.publish(t, long, "long-donor", longer, 100)
	f.publish(t, short, "short-donor", f.checkpoint, 100)
	// Equal load: the larger credit is the cheaper holder and wins. The cold
	// peer is 4 s beyond the short holder and never enters the band.
	selected, decision, pr := f.reserve(t, "equal-load")
	if selected != long || decision.SelectionPath != SelectionCacheCredit || decision.NearTiePoolSize != 2 ||
		decision.RunnerUp.ProviderID != short.ID || pr.CacheOpportunityReason() != "selected" ||
		pr.CacheOpportunity.CreditedCandidates != 2 {
		t.Fatalf("larger credit did not win among equal holders: %s %+v %+v", selected.ID, decision, pr.CacheOpportunity)
	}
	// Two pending turns on other models add 1,500 ms: the longer holder is now
	// the more expensive credited near-tie, and the cheaper holder wins. The
	// credit is already inside the cost, so a larger credit never re-prefers a
	// holder whose load the cost model priced as worse.
	f.pendingTurn(long, "busy-1", "other-model", 0)
	f.pendingTurn(long, "busy-2", "other-model", 0)
	selected, decision, pr = f.reserve(t, "busier-longer-holder")
	if selected != short || decision.SelectionPath != SelectionCacheCredit || decision.NearTiePoolSize != 2 ||
		decision.RunnerUp.ProviderID != long.ID || pr.CacheOpportunityReason() != "selected" {
		t.Fatalf("busier holder with larger credit displaced the cheaper holder: %s %+v", selected.ID, decision)
	}
	wantGap := 2*totalPendingPenaltyMs - (decision.RunnerUp.CacheDiscountMs - decision.CacheDiscountMs)
	if math.Abs(decision.RunnerUp.CostMs-decision.CostMs-wantGap) > .01 {
		t.Fatalf("holder ordering was not by adjusted cost: %+v", decision)
	}
}

func TestCacheCreditPoolWithoutCreditKeepsLoadSpreading(t *testing.T) {
	f := newCreditTestFixture(t)
	a, b := f.cold(t, "a"), f.cold(t, "b")
	f.pendingTurn(b, "other-turn", "other-model", 0)
	selected, decision, pr := f.reserve(t, "spread-pending")
	if selected != a || decision.SelectionPath != SelectionTiePending || decision.NearTiePoolSize != 2 ||
		pr.CacheOpportunityReason() != "no_repeat_observed" || pr.CacheOpportunity.CreditedCandidates != 0 {
		t.Fatalf("near-tie load spreading changed without cache credit: %s %+v", selected.ID, decision)
	}
	b.RemovePending("other-turn")
	seen := map[string]bool{}
	for i := range 40 {
		selected, decision, _ := f.reserve(t, fmt.Sprintf("spread-random-%d", i))
		if decision.SelectionPath != SelectionRandom || decision.NearTiePoolSize != 2 {
			t.Fatalf("equivalent cold peers were not spread at random: %+v", decision)
		}
		seen[selected.ID] = true
	}
	if !seen[a.ID] || !seen[b.ID] {
		t.Fatalf("random spreading concentrated on one peer: %v", seen)
	}
}

func TestCacheCreditAffinityStillAppliesWhenHolderIsBeyondBand(t *testing.T) {
	f := newCreditTestFixture(t)
	holder := f.holder(t, "holder")
	f.publish(t, holder, "donor", f.checkpoint, 100)
	peers := []*Provider{f.holder(t, "peer-a"), f.holder(t, "peer-b")}
	holder.mu.Lock()
	holder.BackendCapacity.Slots[0].NumWaiting = 3 // 9 s of queue penalty: outside the band.
	holder.mu.Unlock()
	for range 2 {
		f.r.cacheRouting.observeCacheDemand(&f.plan, f.r.cacheRouteKeys.route, time.Now())
	}
	if f.plan.affinityKey == "" {
		t.Fatal("repeat demand did not produce affinity")
	}
	var first *Provider
	for i := range 5 {
		selected, decision, pr := f.reserve(t, fmt.Sprintf("affinity-%d", i))
		if selected == holder || decision.SelectionPath != SelectionPrefixAffinity || !pr.CacheOpportunity.AffinityApplied ||
			pr.CacheOpportunity.CreditedCandidates != 1 || pr.CacheOpportunityReason() != "holder_not_selected" ||
			decision.CacheDiscountMs != 0 || pr.CacheSelectionSelected {
			t.Fatalf("credited holder beyond the band disabled affinity: %s %+v %+v", selected.ID, decision, pr.CacheOpportunity)
		}
		if first == nil {
			first = selected
		} else if selected != first {
			t.Fatal("affinity winner moved between identical evaluations")
		}
	}
	if first != peers[0] && first != peers[1] {
		t.Fatalf("affinity chose %s, want a cache-capable peer", first.ID)
	}
}

func TestCacheCreditRestorePenaltyNeverBeatsCheaperColdPeer(t *testing.T) {
	f := newCreditTestFixture(t)
	holder, cold := f.holder(t, "holder"), f.cold(t, "cold")
	// 4,096 tokens at 5,000 tok/s recompute in 819 ms; a 900 ms stage is an
	// 81 ms restore penalty. The cold peer decodes four times faster and
	// carries a pending turn on another model, so it is cheaper yet busier:
	// least-busy spreading would prefer the penalized holder if it entered
	// the band.
	setTestProviderRates(holder, 5000, 100)
	setTestProviderRates(cold, 5000, 400)
	f.publish(t, holder, "donor", f.checkpoint, 900)
	f.pendingTurn(cold, "other-turn", "other-model", 0)
	for round := range 3 {
		selected, decision, pr := f.reserve(t, fmt.Sprintf("penalty-%d", round))
		if selected != cold || decision.SelectionPath != SelectionUniqueMin || decision.NearTiePoolSize != 1 ||
			decision.RunnerUp.ProviderID != holder.ID || decision.RunnerUp.CostMs <= decision.CostMs ||
			decision.RunnerUp.CostMs-decision.CostMs > nearTieCostWindowMs {
			t.Fatalf("restore penalty displaced a cheaper cold peer: %s %+v", selected.ID, decision)
		}
		if got := pr.CacheOpportunityReason(); got != "holder_no_positive_credit" || pr.CacheOpportunity.UsableCandidates != 1 {
			t.Fatalf("reason=%s: %+v", got, pr.CacheOpportunity)
		}
	}
}

type rescanExpectation struct {
	want    string
	path    SelectionPath
	nearTie int
	reason  string
}

func checkRescanExpectation(t *testing.T, label string, selected *Provider, decision RoutingDecision, pr *PendingRequest, want rescanExpectation) {
	t.Helper()
	if selected.ID != want.want || decision.SelectionPath != want.path || decision.NearTiePoolSize != want.nearTie ||
		pr.CacheOpportunityReason() != want.reason {
		t.Fatalf("%s: %s path=%s near=%d reason=%s, want %+v: %+v", label, selected.ID, decision.SelectionPath,
			decision.NearTiePoolSize, pr.CacheOpportunityReason(), want, decision)
	}
}

func TestCacheCreditReservationRescanMatchesFreshScan(t *testing.T) {
	for _, tc := range []struct {
		name   string
		mutate string // which provider gains a same-model pending turn during the first scan
		scans  int
		commit rescanExpectation
		fresh  rescanExpectation
	}{
		// The winner changed under the scan: the commit rescans, and the busier
		// holder now sits ~8 s above the cold peer. The committed decision is
		// the rescan's, and a fresh scan of the same pool reproduces it.
		{name: "winner_changed", mutate: "holder", scans: 2,
			commit: rescanExpectation{"cold", SelectionUniqueMin, 1, "holder_not_selected"},
			fresh:  rescanExpectation{"cold", SelectionUniqueMin, 1, "holder_not_selected"}},
		// Only the runner-up changed: the winner's terms still match the scan,
		// so the commit proceeds without a rescan and reports the scan it
		// committed from. A fresh scan sees the busier cold peer beyond the
		// band, with the same holder cost and credit.
		{name: "runner_up_changed", mutate: "cold", scans: 1,
			commit: rescanExpectation{"holder", SelectionCacheCredit, 2, "selected_near_tie"},
			fresh:  rescanExpectation{"holder", SelectionUniqueMin, 1, "selected"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := newCreditTestFixture(t)
			holder, cold := f.holder(t, "holder"), f.cold(t, "cold")
			f.publish(t, holder, "donor", f.checkpoint, 100)
			f.pendingTurn(holder, "previous-turn", "model", 100)
			target := holder
			if tc.mutate == "cold" {
				target = cold
			}
			scans := 0
			f.r.reservationAfterScan = func(string) {
				scans++
				if scans == 1 {
					f.pendingTurn(target, "concurrent-turn", "model", 100)
				}
			}
			selected, decision, pr := f.reserve(t, "rescanned")
			if decision.ScanCount != tc.scans || scans != tc.scans {
				t.Fatalf("scans=%d/%d want %d", decision.ScanCount, scans, tc.scans)
			}
			checkRescanExpectation(t, "committed", selected, decision, pr, tc.commit)
			f.r.reservationAfterScan = nil
			again, fresh, freshPR := f.reserve(t, "fresh")
			checkRescanExpectation(t, "fresh", again, fresh, freshPR, tc.fresh)
			// The evidence weight decays with wall-clock age between two separate
			// queries (1 minute TTL): allow that drift and nothing else.
			if again != selected || math.Abs(fresh.CostMs-decision.CostMs) > 1 ||
				math.Abs(fresh.CacheDiscountMs-decision.CacheDiscountMs) > 1 {
				t.Fatalf("fresh scan diverged from the committed winner: %+v vs %+v", fresh, decision)
			}
		})
	}
}
