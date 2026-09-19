package registry

import (
	"context"
	"fmt"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func routingAffinityFixture(t *testing.T, mode string) (*Registry, []*Provider) {
	t.Helper()
	r := New(testLogger())
	if err := r.ConfigureAccountAffinity(AccountAffinityConfig{Mode: mode, MaxTTFTPenaltyMs: 250}); err != nil {
		t.Fatal(err)
	}
	providers := make([]*Provider, 3)
	for i := range providers {
		p := makeSchedulerProvider(t, r, fmt.Sprintf("session-%d", i), "affinity-build", 100)
		p.mu.Lock()
		p.AttestationResult = &attestation.VerificationResult{Valid: true, SerialNumber: fmt.Sprintf("machine-%d", i)}
		p.AccountID = "same-provider-owner"
		p.PrefillTPS = 1000
		p.BackendCapacity.Slots[0].MaxConcurrency = 4
		p.mu.Unlock()
		providers[i] = p
	}
	return r, providers
}

func routingAffinityRequest(id string) *PendingRequest {
	return &PendingRequest{
		RequestID: id, ConsumerKey: "authenticated-account", Model: "affinity-build",
		EstimatedPromptTokens: 100, RequestedMaxTokens: 128, MinDecodeTPS: 15,
		FirstContentDeadline: time.Now().Add(5 * time.Second), MaxTTFTMs: 5000,
	}
}

func TestAccountAffinityReservationAccountNotAPIKey(t *testing.T) {
	r, _ := routingAffinityFixture(t, AccountAffinityOn)
	var expected *Provider
	for i := 0; i < 20; i++ {
		pr := routingAffinityRequest(fmt.Sprint(i))
		pr.KeyID = fmt.Sprintf("different-api-key-%d", i)
		p, d := r.ReserveProviderEx(pr.Model, pr)
		if p == nil || !d.AccountAffinity.Applied || d.SelectionPath != SelectionAccountAffinity {
			t.Fatalf("not affinity-routed: provider=%v observation=%+v", p, d.AccountAffinity)
		}
		if expected != nil && p != expected {
			t.Fatal("different API key/request ID moved the account")
		}
		expected = p
		p.RemovePending(pr.RequestID)
	}
}

func TestAccountAffinityReservationRevalidatesInputsAndConfig(t *testing.T) {
	for _, change := range []string{"identity", "prefill", "mode", "deadline"} {
		t.Run(change, func(t *testing.T) {
			r, _ := routingAffinityFixture(t, AccountAffinityOn)
			pr := routingAffinityRequest("scan-commit")
			scan := r.scanProviderReservation(pr.Model, pr)
			if scan.selected == nil || !scan.candidates.accountAffinity.Applied {
				t.Fatal("missing initial affinity selection")
			}
			p := scan.selected.provider
			switch change {
			case "identity":
				p.mu.Lock()
				p.AttestationResult.SerialNumber = "new-physical-identity"
				p.mu.Unlock()
			case "prefill":
				p.mu.Lock()
				p.PrefillTPS = 500
				p.mu.Unlock()
			case "mode":
				if err := r.ConfigureAccountAffinity(AccountAffinityConfig{Mode: AccountAffinityOff, MaxTTFTPenaltyMs: 250}); err != nil {
					t.Fatal(err)
				}
			case "deadline":
				pr.FirstContentDeadline = time.Now().Add(-time.Millisecond)
			}
			got, _, outcome, _ := r.commitProviderReservation(pr.Model, pr, scan)
			if got != nil || (outcome != reservationNeedsRescan && outcome != reservationDeadlineExpired) {
				t.Fatalf("stale choice committed: %v outcome=%v", got, outcome)
			}
			if p.PendingCount() != 0 {
				t.Fatal("rejected commit leaked a pending reservation")
			}
		})
	}
}

func TestAccountAffinityReservationSpillsAndReturns(t *testing.T) {
	r, _ := routingAffinityFixture(t, AccountAffinityOn)
	first := routingAffinityRequest("first")
	preferred, _ := r.ReserveProviderEx(first.Model, first)
	if preferred == nil {
		t.Fatal("no preferred provider")
	}
	preferred.RemovePending(first.RequestID)
	preferred.mu.Lock()
	preferred.BackendCapacity.Slots[0].NumWaiting = 3 // 300ms of queued prefill, plus contention.
	preferred.mu.Unlock()
	spill := routingAffinityRequest("spill")
	next, decision := r.ReserveProviderEx(spill.Model, spill)
	if next == nil || next == preferred || !decision.AccountAffinity.Applied || decision.AccountAffinity.Rank < 2 {
		t.Fatalf("did not spill in stable order: provider=%v observation=%+v", next, decision.AccountAffinity)
	}
	next.RemovePending(spill.RequestID)
	preferred.mu.Lock()
	preferred.BackendCapacity.Slots[0].NumWaiting = 0
	preferred.mu.Unlock()
	back := routingAffinityRequest("back")
	got, _ := r.ReserveProviderEx(back.Model, back)
	if got != preferred {
		t.Fatal("account did not return to recovered preferred provider")
	}
	got.RemovePending(back.RequestID)
}

func TestAccountAffinityQueueDrainUsesAccount(t *testing.T) {
	r, _ := routingAffinityFixture(t, AccountAffinityOn)
	first := routingAffinityRequest("primary")
	preferred, _ := r.ReserveProviderEx(first.Model, first)
	if preferred == nil {
		t.Fatal("no primary")
	}
	preferred.RemovePending(first.RequestID)
	r.SetQueue(NewRequestQueue(4, time.Second))
	pr := routingAffinityRequest("queued")
	queued := enqueueTTFTWaiter(t, r, pr)
	r.DrainQueuedRequestsForModel(pr.Model)
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	got, err := r.Queue().WaitForProviderContext(ctx, queued)
	if err != nil || got != preferred || !queued.Decision.AccountAffinity.Applied {
		t.Fatalf("queue lost affinity: got=%v err=%v observation=%+v", got, err, queued.Decision.AccountAffinity)
	}
	got.RemovePending(pr.RequestID)
}

func TestAccountAffinityConcurrentReservationsBoundedAndReleased(t *testing.T) {
	forEachCommitMode(t, func(t *testing.T, mode reserveCommitMode) {
		r, providers := routingAffinityFixture(t, AccountAffinityOn)
		setReserveCommitModeForTest(r, mode)
		var wg sync.WaitGroup
		for i := 0; i < 32; i++ {
			wg.Add(1)
			go func(i int) {
				defer wg.Done()
				pr := routingAffinityRequest(fmt.Sprintf("parallel-%d", i))
				r.ReserveProviderEx(pr.Model, pr)
			}(i)
		}
		wg.Wait()
		total := 0
		for _, p := range providers {
			count := p.PendingCount()
			if count > 4 {
				t.Fatalf("over-reserved provider: %d > 4", count)
			}
			total += count
			for i := 0; i < 32; i++ {
				p.RemovePending(fmt.Sprintf("parallel-%d", i))
			}
			if p.PendingCount() != 0 {
				t.Fatal("reservation leaked after release")
			}
		}
		if total != 12 {
			t.Fatalf("soft affinity stranded capacity: got=%d want=12", total)
		}
	})
}

func TestAccountAffinityCannotOverrideAdmission(t *testing.T) {
	for _, failure := range []string{"trust", "capacity", "kv_budget", "thermal"} {
		t.Run(failure, func(t *testing.T) {
			r, _ := routingAffinityFixture(t, AccountAffinityOn)
			first := routingAffinityRequest("find-primary")
			preferred, _ := r.ReserveProviderEx(first.Model, first)
			if preferred == nil {
				t.Fatal("missing initial provider")
			}
			preferred.RemovePending(first.RequestID)
			preferred.mu.Lock()
			switch failure {
			case "trust":
				preferred.TrustLevel = TrustSelfSigned
			case "capacity":
				preferred.BackendCapacity.Slots[0].NumRunning = 4
			case "kv_budget":
				preferred.BackendCapacity.Slots[0].ActiveTokenBudgetMax = 100
			case "thermal":
				preferred.SystemMetrics.ThermalState = "critical"
			}
			preferred.mu.Unlock()
			pr := routingAffinityRequest("gated")
			got, _ := r.ReserveProviderEx(pr.Model, pr)
			if got == nil || got == preferred {
				t.Fatalf("affinity bypassed %s: %v", failure, got)
			}
			if preferred.PendingCount() != 0 {
				t.Fatal("excluded primary consumed capacity")
			}
			got.RemovePending(pr.RequestID)
		})
	}
}

func TestAccountAffinityShadowPreservesLegacySelection(t *testing.T) {
	r, providers := routingAffinityFixture(t, AccountAffinityShadow)
	// Make the ordinary winner unique; shadow must not change it even for
	// accounts whose HRW winner is another otherwise-feasible provider.
	providers[0].mu.Lock()
	providers[0].DecodeTPS = 1000
	providers[0].mu.Unlock()
	sawDifference := false
	for i := 0; i < 40; i++ {
		pr := routingAffinityRequest(fmt.Sprintf("shadow-%d", i))
		pr.ConsumerKey = fmt.Sprintf("account-%d", i)
		pr.RequestedMaxTokens = 1024
		p, d := r.ReserveProviderEx(pr.Model, pr)
		if p != providers[0] || d.AccountAffinity.Applied || !d.AccountAffinity.Evaluated {
			t.Fatalf("shadow changed ordinary selection: provider=%v observation=%+v", p, d.AccountAffinity)
		}
		sawDifference = sawDifference || d.AccountAffinity.WouldChange
		p.RemovePending(pr.RequestID)
	}
	if !sawDifference {
		t.Fatal("shadow did not evaluate a differing counterfactual")
	}
}

func TestAccountAffinityWholeMachineReportedWork(t *testing.T) {
	r, _ := routingAffinityFixture(t, AccountAffinityOn)
	pr := routingAffinityRequest("find-machine")
	preferred, _ := r.ReserveProviderEx(pr.Model, pr)
	if preferred == nil {
		t.Fatal("no primary")
	}
	preferred.RemovePending(pr.RequestID)
	preferred.mu.Lock()
	// This work isn't in the coordinator's pending ledger or the target
	// model's slot, but it still contends for the same GPU.
	preferred.BackendCapacity.Slots = append(preferred.BackendCapacity.Slots,
		protocol.BackendSlotCapacity{Model: "other-model", State: "running", NumRunning: 16})
	preferred.mu.Unlock()
	next := routingAffinityRequest("cross-model-spill")
	got, d := r.ReserveProviderEx(next.Model, next)
	if got == nil || got == preferred || !d.AccountAffinity.Applied {
		t.Fatalf("ignored other-slot work: provider=%v observation=%+v", got, d.AccountAffinity)
	}
	got.RemovePending(next.RequestID)
}

func TestAccountAffinityReportedWorkSaturates(t *testing.T) {
	const maxInt = int(^uint(0) >> 1)
	for _, tc := range []struct {
		slots []protocol.BackendSlotCapacity
		want  int
	}{
		{nil, 0},
		{[]protocol.BackendSlotCapacity{{NumRunning: 2, NumWaiting: 3}, {NumRunning: -100, NumWaiting: 1}}, 6},
		{[]protocol.BackendSlotCapacity{{NumRunning: maxInt, NumWaiting: 1}}, maxInt},
	} {
		if got := accountAffinityReportedOccupancy(tc.slots); got != tc.want {
			t.Fatalf("reported occupancy=%d want=%d", got, tc.want)
		}
	}
}

func TestAccountAffinityFailedCommitIsNotReportedApplied(t *testing.T) {
	r, providers := routingAffinityFixture(t, AccountAffinityOn)
	pr := routingAffinityRequest("deadline-after-scan")
	r.reservationAfterScan = func(string) {
		pr.FirstContentDeadline = time.Now().Add(-time.Millisecond)
	}
	p, decision := r.ReserveProviderEx(pr.Model, pr)
	if p != nil || !decision.AccountAffinity.Evaluated || decision.AccountAffinity.Applied {
		t.Fatalf("failed commit reported applied preference: provider=%v observation=%+v", p, decision.AccountAffinity)
	}
	for _, provider := range providers {
		if provider.PendingCount() != 0 {
			t.Fatal("expired affinity proposal consumed capacity")
		}
	}
}

func TestAccountAffinityReservationKeepsSlowerIdleHome(t *testing.T) {
	r, providers := routingAffinityFixture(t, AccountAffinityOn)
	initial := routingAffinityRequest("initial-home")
	home, _ := r.ReserveProviderEx(initial.Model, initial)
	if home == nil {
		t.Fatal("no initial home")
	}
	home.RemovePending(initial.RequestID)
	for _, p := range providers {
		p.mu.Lock()
		p.PrefillTPS = 100_000.0 / 390 // 400ms including the live first decode.
		if p == home {
			p.PrefillTPS = 100_000.0 / 890 // Intrinsic 900ms; no queued work.
		}
		p.mu.Unlock()
	}
	pr := routingAffinityRequest("slower-idle-home")
	p, d := r.ReserveProviderEx(pr.Model, pr)
	if p != home || !d.AccountAffinity.Applied || d.AccountAffinity.AddedTTFTMs != 0 {
		t.Fatalf("idle 900ms home displaced by 400ms alternatives: provider=%v observation=%+v", p, d.AccountAffinity)
	}
	p.RemovePending(pr.RequestID)
}
