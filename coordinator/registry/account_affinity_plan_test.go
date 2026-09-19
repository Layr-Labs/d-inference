package registry

import (
	"bytes"
	"fmt"
	"math"
	"sort"
	"sync"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func accountAffinityPlanFixture(t *testing.T, count int) (*Registry, []*Provider) {
	t.Helper()
	r, providers := routingAffinityFixture(t, AccountAffinityOn)
	for i := len(providers); i < count; i++ {
		p := makeSchedulerProvider(t, r, fmt.Sprintf("session-%d", i), "affinity-build", 100)
		p.mu.Lock()
		p.AttestationResult = &attestation.VerificationResult{Valid: true, SerialNumber: fmt.Sprintf("machine-%d", i)}
		p.PrefillTPS = 1000
		p.BackendCapacity.Slots[0].MaxConcurrency = 4
		p.mu.Unlock()
		providers = append(providers, p)
	}
	return r, providers
}

func accountAffinityPlanOrder(providers []*Provider, pr *PendingRequest) []*Provider {
	ordered := append([]*Provider(nil), providers...)
	sort.Slice(ordered, func(i, j int) bool {
		a := accountAffinityScore(pr.ConsumerKey, pr.Model, stableAccountAffinityIdentityLocked(ordered[i]))
		b := accountAffinityScore(pr.ConsumerKey, pr.Model, stableAccountAffinityIdentityLocked(ordered[j]))
		return bytes.Compare(a[:], b[:]) > 0
	})
	return ordered
}

func TestAccountAffinityPlanRetainsBoundedHRWAlternatesAndRefresh(t *testing.T) {
	r, providers := accountAffinityPlanFixture(t, 20)
	pr := routingAffinityRequest("plan-primary")
	ordered := accountAffinityPlanOrder(providers, pr)
	primary, _, plan := r.ReserveProviderWithPlan(pr.Model, pr)
	if primary != ordered[0] || plan == nil || plan.Len() != dispatchPlanMaxAlternates || !plan.affinity.enabled {
		t.Fatal("primary did not retain a bounded account-affinity plan")
	}
	primary.RemovePending(pr.RequestID)
	for i, entry := range plan.entries {
		if entry.provider != ordered[i+1] {
			t.Fatalf("alternate %d is %s, want stable rank %s", i, entry.provider.ID, ordered[i+1].ID)
		}
	}
	for i := 1; i <= dispatchPlanMaxAlternates; i++ {
		retry := routingAffinityRequest(fmt.Sprintf("plan-retry-%d", i))
		retry.KeyID = fmt.Sprintf("different-key-%d", i)
		got, decision, _ := r.ReserveNextFromPlan(retry, plan)
		if got != ordered[i] || !decision.AccountAffinity.Applied {
			t.Fatalf("retry %d lost HRW order: got=%v observation=%+v", i, got, decision.AccountAffinity)
		}
		got.RemovePending(retry.RequestID)
	}
	refresh := routingAffinityRequest("refresh")
	got, _, fresh, performed := r.RefreshDispatchPlan(refresh, plan)
	if !performed || got != ordered[dispatchPlanMaxAlternates+1] || fresh == nil || !fresh.RefreshUsed() {
		t.Fatal("one-shot refresh did not retain the next stable unattempted identity")
	}
	got.RemovePending(refresh.RequestID)
	for i, entry := range fresh.entries {
		if entry.provider != ordered[dispatchPlanMaxAlternates+2+i] {
			t.Fatal("refresh changed relative affinity order")
		}
	}
}

func TestAccountAffinityPlanQuotesPreserveRankAndDemoteNegative(t *testing.T) {
	r, _ := accountAffinityPlanFixture(t, 3)
	pr := routingAffinityRequest("quotes")
	primary, _, plan := r.ReserveProviderWithPlan(pr.Model, pr)
	if primary == nil || plan == nil || plan.Len() != 2 {
		t.Fatal("missing plan")
	}
	defer primary.RemovePending(pr.RequestID)
	first, second := plan.entries[0].view.ProviderID, plan.entries[1].view.ProviderID
	plan.ConfirmEntry(second, &protocol.CapacityQuoteMessage{TTFTP90MS: 100})
	if next, _ := plan.PeekNext(); next.ProviderID != first {
		t.Fatal("affirmative quote scrambled stable affinity")
	}
	plan.DemoteEntry(first)
	if next, _ := plan.PeekNext(); next.ProviderID != second {
		t.Fatal("negative quote did not yield to a usable alternate")
	}
	retry := routingAffinityRequest("negative-quote-retry")
	got, _, _ := r.ReserveNextFromPlan(retry, plan)
	if got == nil || got.ID != second {
		t.Fatal("negative quote starved the confirmed alternate")
	}
	got.RemovePending(retry.RequestID)
}

func TestAccountAffinityPlanLiveBusySpillAndRecovery(t *testing.T) {
	r, _ := accountAffinityPlanFixture(t, 3)
	pr := routingAffinityRequest("live-plan")
	primary, _, plan := r.ReserveProviderWithPlan(pr.Model, pr)
	if primary == nil || plan == nil || plan.Len() != 2 {
		t.Fatal("missing plan")
	}
	primary.RemovePending(pr.RequestID)
	first, second := plan.entries[0].provider, plan.entries[1].provider
	first.mu.Lock()
	first.BackendCapacity.Slots[0].NumWaiting = 3 // 300ms of queued prefill, plus decode contention
	first.mu.Unlock()
	retry := routingAffinityRequest("busy-retry")
	got, d, _ := r.ReserveNextFromPlan(retry, plan)
	if got != second || !d.AccountAffinity.Applied || plan.Remaining() != 1 {
		t.Fatalf("live spill failed: got=%v observation=%+v remaining=%d", got, d.AccountAffinity, plan.Remaining())
	}
	got.RemovePending(retry.RequestID)
	first.mu.Lock()
	first.BackendCapacity.Slots[0].NumWaiting = 0
	first.mu.Unlock()
	retry = routingAffinityRequest("recovered-retry")
	got, d, _ = r.ReserveNextFromPlan(retry, plan)
	if got != first || !d.AccountAffinity.Applied {
		t.Fatal("recovered identity was discarded instead of re-evaluated")
	}
	got.RemovePending(retry.RequestID)
}

func TestAccountAffinityPlanRetainsInitiallyBusyIdentity(t *testing.T) {
	r, providers := accountAffinityPlanFixture(t, 3)
	pr := routingAffinityRequest("initially-busy")
	ordered := accountAffinityPlanOrder(providers, pr)
	ordered[1].mu.Lock()
	ordered[1].BackendCapacity.Slots[0].NumWaiting = 3
	ordered[1].mu.Unlock()
	primary, _, plan := r.ReserveProviderWithPlan(pr.Model, pr)
	if primary != ordered[0] || plan == nil || plan.entries[0].provider != ordered[1] {
		t.Fatal("temporarily busy identity was not retained by stable rank")
	}
	primary.RemovePending(pr.RequestID)
	ordered[1].mu.Lock()
	ordered[1].BackendCapacity.Slots[0].NumWaiting = 0
	ordered[1].mu.Unlock()
	retry := routingAffinityRequest("initially-busy-recovered")
	got, d, _ := r.ReserveNextFromPlan(retry, plan)
	if got != ordered[1] || !d.AccountAffinity.Applied {
		t.Fatal("recovered initial alternate did not reclaim its stable rank")
	}
	got.RemovePending(retry.RequestID)
}

func TestAccountAffinityPlanBusyRanksCannotCrowdOutReadyBackups(t *testing.T) {
	r, providers := accountAffinityPlanFixture(t, 20)
	pr := routingAffinityRequest("many-busy-ranks")
	ordered := accountAffinityPlanOrder(providers, pr)
	for _, p := range ordered[:9] {
		p.mu.Lock()
		p.BackendCapacity.Slots[0].NumWaiting = 3 // hard-admissible, but too much same-machine queued work
		p.mu.Unlock()
	}
	primary, _, plan := r.ReserveProviderWithPlan(pr.Model, pr)
	if primary != ordered[9] || plan == nil || plan.Len() != dispatchPlanMaxAlternates {
		t.Fatal("fixture did not spill the primary past busy high-HRW ranks")
	}
	primary.RemovePending(pr.RequestID)
	for i, entry := range plan.entries {
		if entry.provider != ordered[10+i] {
			t.Fatal("busy high-HRW identities crowded a ready backup out of the bounded plan")
		}
	}
	retry := routingAffinityRequest("ready-backup")
	got, d, _ := r.ReserveNextFromPlan(retry, plan)
	if got != ordered[10] || !d.AccountAffinity.Applied {
		t.Fatal("retry fell back to busy ranks despite known-ready alternatives")
	}
	got.RemovePending(retry.RequestID)
}

func TestAccountAffinityPlanIntrinsicSpeedDoesNotChangeStableOrder(t *testing.T) {
	for _, loaded := range []bool{false, true} {
		t.Run(map[bool]string{false: "idle_900ms_preferred", true: "loaded_spills_to_600ms_before_400ms"}[loaded], func(t *testing.T) {
			r, providers := accountAffinityPlanFixture(t, 4)
			pr := routingAffinityRequest("intrinsic-primary")
			ordered := accountAffinityPlanOrder(providers, pr)
			// All have the same 10ms intrinsic first-decode estimate. Their own
			// prompt-prefill speeds make HRW ranks 2/3/4 predict 900/600/400ms.
			for i, ttftMs := range []float64{900, 600, 400} {
				p := ordered[i+1]
				p.mu.Lock()
				p.PrefillTPS = 100_000 / (ttftMs - 10)
				p.mu.Unlock()
			}
			primary, _, plan := r.ReserveProviderWithPlan(pr.Model, pr)
			if primary != ordered[0] || plan == nil || plan.Len() != 3 {
				t.Fatal("fixture did not retain the intrinsic-speed alternatives")
			}
			primary.RemovePending(pr.RequestID)
			want, wantTTFT := ordered[1], 900.0
			if loaded {
				ordered[1].mu.Lock()
				ordered[1].BackendCapacity.Slots[0].NumWaiting = 1
				ordered[1].mu.Unlock()
				want, wantTTFT = ordered[2], 600.0
			}
			retry := routingAffinityRequest("intrinsic-retry")
			got, decision, _ := r.ReserveNextFromPlan(retry, plan)
			if got != want || !decision.AccountAffinity.Applied ||
				math.Abs(decision.TTFTMs-wantTTFT) > 0.001 || decision.AccountAffinity.AddedTTFTMs != 0 {
				t.Fatalf("intrinsic speed replaced stable affinity: got=%v want=%s TTFT=%f observation=%+v", got, want.ID, decision.TTFTMs, decision.AccountAffinity)
			}
			got.RemovePending(retry.RequestID)
		})
	}
}

func TestAccountAffinityPlanConcurrentConsumersDoNotReuseEntries(t *testing.T) {
	forEachCommitMode(t, func(t *testing.T, mode reserveCommitMode) {
		r, providers := accountAffinityPlanFixture(t, 12)
		setReserveCommitModeForTest(r, mode)
		pr := routingAffinityRequest("parallel-plan")
		primary, _, plan := r.ReserveProviderWithPlan(pr.Model, pr)
		if primary == nil || plan == nil {
			t.Fatal("missing plan")
		}
		primary.RemovePending(pr.RequestID)
		var wg sync.WaitGroup
		results := make(chan *Provider, 32)
		for i := range 32 {
			wg.Add(1)
			go func(i int) {
				defer wg.Done()
				retry := routingAffinityRequest(fmt.Sprintf("parallel-plan-%d", i))
				p, _, _ := r.ReserveNextFromPlan(retry, plan)
				results <- p
			}(i)
		}
		wg.Wait()
		close(results)
		seen := make(map[*Provider]bool)
		for p := range results {
			if p == nil {
				continue
			}
			if seen[p] {
				t.Fatal("two consumers reserved the same plan entry")
			}
			seen[p] = true
		}
		if len(seen) != dispatchPlanMaxAlternates || plan.Remaining() != 0 || len(plan.AttemptedProviderIDs()) != dispatchPlanMaxAlternates+1 {
			t.Fatal("concurrent consumers leaked or grew bounded plan state")
		}
		for _, p := range providers {
			for i := range 32 {
				p.RemovePending(fmt.Sprintf("parallel-plan-%d", i))
			}
			if p.PendingCount() != 0 {
				t.Fatal("reservation leaked after release")
			}
		}
	})
}
