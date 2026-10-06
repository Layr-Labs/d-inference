package registry_test

import (
	"fmt"
	"math"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachedemand"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachehistory"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	. "github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/registry/selection"
)

// creditTestFixture exercises validated checkpoint evidence through the live
// scan and atomic commit. Rates are explicit, and a 4,096-token checkpoint
// saves 3,996 ms on a 1,000 tok/s provider after its 100 ms restore. Physical
// reservations and the historical cost diagnostics remain independently visible.
type creditTestFixture struct {
	r                 *exactRoutingFixture
	demand            *cachedemand.Tracker
	capability        protocol.PrefixCacheV2Capability
	plan              CachePlan
	checkpoint, floor protocol.PrefixCacheAnchor
}

func newCreditTestFixture(t *testing.T, dependencies ...Dependencies) creditTestFixture {
	t.Helper()
	var deps Dependencies
	if len(dependencies) != 0 {
		deps = dependencies[0]
	}
	var demand *cachedemand.Tracker
	deps.Cache.Demand = func(limit int, ttl time.Duration, history *cachehistory.Index) *cachedemand.Tracker {
		demand = cachedemand.New(limit, ttl, history)
		return demand
	}
	r, _, _ := newExactRoutingFixture(t, deps)
	r.Disconnect("provider-a")
	checkpointPricingUncap(t, r.Registry)
	checkpoint, floor := exactTestAnchor(16, "c"), exactTestAnchor(17, "d")
	return creditTestFixture{r: r, demand: demand, capability: checkpointPricingCapability(1),
		plan: boundTestCachePlan(r, exactTestPlan(checkpoint, floor)), checkpoint: checkpoint, floor: floor}
}

func setTestProviderRates(p *Provider, prefillTPS, decodeTPS float64) {
	p.Mu().Lock()
	p.PrefillTPS = prefillTPS
	p.BackendCapacity.Slots[0].ObservedPrefillTPS = prefillTPS
	p.BackendCapacity.Slots[0].ObservedDecodeTPS = decodeTPS
	p.Mu().Unlock()
}

// holder registers a cache-capable provider; publish gives it durable evidence.
func (f creditTestFixture) holder(t *testing.T, id string) *Provider {
	t.Helper()
	p := checkpointPricingProvider(t, f.r.Registry, id, f.capability)
	setTestProviderRates(p, 1000, 100)
	return p
}

func (f creditTestFixture) cold(t *testing.T, id string) *Provider {
	t.Helper()
	p := makeSchedulerProvider(t, f.r.Registry, id, "model", 100)
	setTestProviderRates(p, 1000, 100)
	return p
}

func (f creditTestFixture) publish(t *testing.T, p *Provider, donor string, anchor protocol.PrefixCacheAnchor, stageMs float64) {
	t.Helper()
	_, ready := checkpointPricingAttempt(t, f.r.Registry, p, f.capability, donor, f.plan, 1)
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

func TestCacheCreditCompetesOnPendingPrefillAndFirstContentBand(t *testing.T) {
	for _, tc := range []struct {
		name    string
		pending int
		want    string
		near    int
		path    SelectionPath
	}{
		{"short_pending_prompt", 100, "holder", 1, SelectionUniqueMin},
		{"close_delivery_prefers_idle_mac", 3900, "cold", 2, SelectionTiePending},
		{"long_pending_prompt", 4300, "cold", 1, SelectionUniqueMin},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f := newCreditTestFixture(t)
			holder, cold := f.holder(t, "holder"), f.cold(t, "cold")
			f.publish(t, holder, "donor", f.checkpoint, 100)
			f.pendingTurn(holder, "previous-turn", "model", tc.pending)
			selected, decision, pr := f.reserve(t, "repeat")
			if selected.ID != tc.want || decision.NearTiePoolSize != tc.near || decision.SelectionPath != tc.path {
				t.Fatalf("winner=%s band=%d path=%s", selected.ID, decision.NearTiePoolSize, decision.SelectionPath)
			}
			if selected == holder {
				if decision.FirstContent.CachedTokens <= 0 || decision.QueueMs != 3000 || decision.BacklogMs <= 0 || !pr.CacheSelectionSelected {
					t.Fatalf("cache or legacy diagnostic lost: %+v", decision)
				}
			} else if selected != cold || decision.CacheDiscountMs != 0 || decision.FirstContent.CachedTokens != 0 {
				t.Fatal("cold peer inherited cache proof")
			}
		})
	}
}

func TestCacheCreditRanksHoldersByExpectedDelivery(t *testing.T) {
	f := newCreditTestFixture(t)
	longer := exactTestAnchor(20, "e")
	f.plan = boundTestCachePlan(f.r, exactTestPlan(f.checkpoint, longer, exactTestAnchor(21, "f")))
	long, short := f.holder(t, "long"), f.holder(t, "short")
	f.cold(t, "cold")
	f.publish(t, long, "long-donor", longer, 100)
	f.publish(t, short, "short-donor", f.checkpoint, 100)
	selected, decision, _ := f.reserve(t, "equal-load")
	if selected != long || decision.SelectionPath != SelectionUniqueMin || decision.NearTiePoolSize != 1 || decision.RunnerUp.ProviderID != short.ID {
		t.Fatal("larger reuse should produce earlier first content")
	}
	f.pendingTurn(long, "busy-prefill", "model", 1200)
	selected, decision, _ = f.reserve(t, "busy-longer-holder")
	if selected != short || decision.RunnerUp.ProviderID != long.ID || decision.FirstContent.ExpectedMs >= decision.RunnerUp.FirstContent.ExpectedMs {
		t.Fatalf("pending prefill did not outweigh reuse: %+v", decision)
	}
}

func TestCacheCreditPoolWithoutCreditKeepsLoadSpreading(t *testing.T) {
	f := newCreditTestFixture(t)
	a, b := f.cold(t, "a"), f.cold(t, "b")
	f.pendingTurn(b, "other-turn", "other-model", 0)
	selected, decision, pr := f.reserve(t, "spread-pending")
	if selected != a || decision.SelectionPath != SelectionUniqueMin || decision.NearTiePoolSize != 1 ||
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
	holder.Mu().Lock()
	holder.BackendCapacity.Slots[0].NumWaiting = 3 // 9 s of queue penalty: outside the band.
	holder.Mu().Unlock()
	for range 2 {
		f.plan.ObserveRouteDemand(f.r.plans.generation, f.demand, f.r.routeKey, time.Now())
	}
	if f.plan.AffinityKey() == "" {
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
	// Restoration takes longer than recomputation. Its actual time must
	// outweigh the cache identity, even with another model on the cold peer.
	setTestProviderRates(holder, 5000, 100)
	setTestProviderRates(cold, 5000, 400)
	f.publish(t, holder, "donor", f.checkpoint, 2000)
	f.pendingTurn(cold, "other-turn", "other-model", 0)
	for round := range 3 {
		selected, decision, pr := f.reserve(t, fmt.Sprintf("penalty-%d", round))
		if selected != cold || decision.SelectionPath != SelectionUniqueMin || decision.NearTiePoolSize != 1 ||
			decision.RunnerUp.ProviderID != holder.ID || decision.RunnerUp.FirstContent.ExpectedMs <= decision.FirstContent.ExpectedMs+selection.FastBandMs {
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
		// holder now has more prefill ahead than the cold peer. The committed decision is
		// the rescan's, and a fresh scan of the same pool reproduces it.
		{name: "winner_changed", mutate: "holder", scans: 2,
			commit: rescanExpectation{"cold", SelectionUniqueMin, 1, "holder_not_selected"},
			fresh:  rescanExpectation{"cold", SelectionUniqueMin, 1, "holder_not_selected"}},
		// Only the runner-up changed: the winner's terms still match the scan,
		// so the commit proceeds without a rescan and reports the scan it
		// committed from. A fresh scan sees the busier cold peer beyond the
		// band, with the same holder forecast and credit.
		{name: "runner_up_changed", mutate: "cold", scans: 1,
			commit: rescanExpectation{"holder", SelectionUniqueMin, 1, "selected"},
			fresh:  rescanExpectation{"holder", SelectionUniqueMin, 1, "selected"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			preparation := &reservationPreparationFixture{}
			f := newCreditTestFixture(t, Dependencies{Reservations: func(planner *ReservationPlanner) ReservationPreparation {
				preparation.planner = planner
				return preparation
			}})
			holder, cold := f.holder(t, "holder"), f.cold(t, "cold")
			f.publish(t, holder, "donor", f.checkpoint, 100)
			f.pendingTurn(holder, "previous-turn", "model", 100)
			target := holder
			if tc.mutate == "cold" {
				target = cold
			}
			scans := 0
			preparation.after = func(string) {
				scans++
				if scans == 1 {
					f.pendingTurn(target, "concurrent-turn", "model", 4300)
				}
			}
			selected, decision, pr := f.reserve(t, "rescanned")
			if decision.ScanCount != tc.scans || scans != tc.scans {
				t.Fatalf("scans=%d/%d want %d", decision.ScanCount, scans, tc.scans)
			}
			checkRescanExpectation(t, "committed", selected, decision, pr, tc.commit)
			preparation.after = nil
			again, fresh, freshPR := f.reserve(t, "fresh")
			checkRescanExpectation(t, "fresh", again, fresh, freshPR, tc.fresh)
			// The evidence weight decays with wall-clock age between two separate
			// queries (1 minute TTL), so compare the time-independent base cost
			// exactly and the credit as a bounded monotone decay of the committed
			// one, rather than pinning either to the wall clock.
			if again != selected || math.Abs((fresh.CostMs+fresh.CacheDiscountMs)-(decision.CostMs+decision.CacheDiscountMs)) > 1e-6 ||
				fresh.CacheDiscountMs > decision.CacheDiscountMs || fresh.CacheDiscountMs < .9*decision.CacheDiscountMs {
				t.Fatalf("fresh scan diverged from the committed winner: %+v vs %+v", fresh, decision)
			}
		})
	}
}

// A burst of same-prefix requests over holders that tie on every ranking term
// must not converge on one holder: the first commit bumps its pending count,
// every other request fails the commit compare and rescans, and a stable
// identity order would send them all to the next holder in turn (K(K+1)/2
// scans for K requests). Uniform spreading keeps most bursts at one scan each.
func TestCacheCreditIdenticalHoldersSpreadConcurrentBurst(t *testing.T) {
	const holders, burst, rounds = 3, 3, 30
	preparation := &reservationPreparationFixture{}
	f := newCreditTestFixture(t, Dependencies{Reservations: func(planner *ReservationPlanner) ReservationPreparation {
		preparation.planner = planner
		return preparation
	}})
	ids := make([]*Provider, holders)
	for i := range ids {
		ids[i] = f.holder(t, fmt.Sprintf("holder-%c", 'a'+i))
	}
	f.cold(t, "cold") // 4 s beyond the holders: never in the band.
	// One Ready receipt per holder for the same checkpoint at the same stage
	// cost; the receipts are microseconds apart, so the age weights differ by
	// well under a nanosecond of credit and the holders rank equal.
	for i, p := range ids {
		f.publish(t, p, fmt.Sprintf("donor-%d", i), f.checkpoint, 100)
	}
	// Equalize the receipt timestamps exactly so every holder's evidence weight
	// is identical at any query time.
	var stamp time.Time
	for _, bucket := range f.r.config.Holders.Buckets() {
		for id, holder := range bucket.Entries() {
			if stamp.IsZero() {
				stamp = holder.UpdatedAt
			}
			holder.UpdatedAt, holder.ExpiresAt = stamp, stamp.Add(f.r.config.TTL)
			bucket.Store(id, holder)
		}
	}

	totalScans, firstScanCommits := 0, 0
	for round := range rounds {
		var mu sync.Mutex
		arrived := 0
		release := make(chan struct{})
		preparation.after = func(string) {
			mu.Lock()
			arrived++
			n := arrived
			if n == burst {
				close(release)
			}
			mu.Unlock()
			if n <= burst {
				<-release // every request of the burst scans the same idle pool
			}
		}
		winners := make([]*Provider, burst)
		scanCounts := make([]int, burst)
		var wg sync.WaitGroup
		for i := range burst {
			wg.Add(1)
			go func(i int) {
				defer wg.Done()
				pr := f.request(fmt.Sprintf("burst-%d-%d", round, i))
				p, decision := f.r.ReserveProviderEx("model", pr)
				// Each commit bumps its holder out of the band, so a rescanning
				// loser may find the last idle holder alone (unique_min); every
				// request must still land on a credited holder.
				if p == nil || decision.CacheDiscountMs <= 0 ||
					(decision.SelectionPath != SelectionCacheCredit && decision.SelectionPath != SelectionUniqueMin) {
					t.Errorf("burst request %d: %+v", i, decision)
					return
				}
				winners[i], scanCounts[i] = p, decision.ScanCount
			}(i)
		}
		wg.Wait()
		preparation.after = nil
		if t.Failed() {
			t.FailNow()
		}
		distinct := map[*Provider]bool{}
		for i, p := range winners {
			distinct[p] = true
			p.RemovePending(fmt.Sprintf("burst-%d-%d", round, i))
			f.r.SetProviderIdle(p.ID)
		}
		if len(distinct) != holders {
			t.Fatalf("round %d: burst landed on %d holders, want %d", round, len(distinct), holders)
		}
		totalScans += arrived
		for _, scans := range scanCounts {
			if scans == 1 {
				firstScanCommits++
			}
		}
	}
	// A request commits on its first scan exactly when its first pick was
	// distinct within the burst. Identity-ordered ties give every request the
	// same first pick, so exactly one request per round commits on its first
	// scan whatever the goroutine schedule; a uniform spread commits about 2.1
	// of 3 per round (P(all three distinct) = 2/9, P(two distinct) = 2/3).
	t.Logf("first-scan commits=%d scans=%d over %d rounds", firstScanCommits, totalScans, rounds)
	if firstScanCommits <= rounds*3/2 {
		t.Fatalf("burst converged on one holder: %d of %d rounds' requests committed on their first scan (identity order gives %d)",
			firstScanCommits, rounds, rounds)
	}
	// Identity-ordered ties scan 5-6 times per round (3 + 2 + 1, minus one
	// when a loser rescans after both other commits); a uniform spread
	// averages about 4.
	if totalScans > 5*rounds {
		t.Fatalf("burst cascaded into %d scans over %d rounds (identity-ordered ties take %d-%d)", totalScans, rounds, 5*rounds, 6*rounds)
	}
}

// A plan alternate is priced and admitted cold; the primary scan's cache
// selection must not describe it at the terminal.
func TestCacheCreditPlanRetryClearsCacheSelection(t *testing.T) {
	f := newCreditTestFixture(t)
	holder, cold := f.holder(t, "holder"), f.cold(t, "cold")
	f.publish(t, holder, "donor", f.checkpoint, 100)
	f.pendingTurn(holder, "previous-turn", "model", 100)
	pr := f.request("retried")
	primary, decision, plan := f.r.ReserveProviderWithPlan("model", pr)
	if primary != holder || plan == nil || decision.SelectionPath != SelectionUniqueMin ||
		!pr.CacheSelectionSelected || pr.CacheOpportunity.CreditWonNearTie || pr.CacheOpportunityReason() != "selected" {
		t.Fatalf("primary reservation did not select the credited holder: %v %+v %+v", primary, decision, pr.CacheOpportunity)
	}
	// Pre-content failure on the holder: the dispatcher releases it and takes
	// the next plan entry with the holder excluded.
	holder.RemovePending(pr.RequestID)
	f.r.SetProviderIdle(holder.ID)
	alternate, retry, skips := f.r.ReserveNextFromPlan(pr, plan, holder.ID)
	if alternate != cold {
		t.Fatalf("plan retry reserved %v, want cold: %+v skips=%v", alternate, retry, skips)
	}
	defer func() { cold.RemovePending(pr.RequestID); f.r.SetProviderIdle(cold.ID) }()
	if pr.CacheSelectionSelected || pr.CacheOpportunity.CreditWonNearTie || pr.CacheSelectionTier != "" ||
		pr.CacheSelectionDiscountMs != 0 || pr.CacheSelectionEstimatedTTFTSavedMs != 0 ||
		retry.CacheDiscountMs != 0 || retry.CacheTier != "" {
		t.Fatalf("plan alternate inherited the primary cache selection: %+v %+v", retry, pr.CacheOpportunity)
	}
	if pr.CacheSelectionMode != "active" || pr.CacheOpportunityReason() != "holder_unavailable" ||
		pr.CacheOpportunity.CreditedCandidates != 0 {
		t.Fatalf("plan retry lost participation or opportunity evidence: mode=%q reason=%s %+v",
			pr.CacheSelectionMode, pr.CacheOpportunityReason(), pr.CacheOpportunity)
	}
}
