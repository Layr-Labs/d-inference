package registry

import (
	"fmt"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// TestReserveProviderCountsCommitRescans pins the rescan counters: when a
// concurrent reservation debits the winner between the shared scan and the
// commit re-check, the discarded iteration is counted (Rescans) and costed
// (RescanUS), while LockWaitUS/ScanUS/AdmitUS keep describing the iteration
// that committed — attempt_profile.go derives the lock-acquired stamp from
// them.
func TestReserveProviderCountsCommitRescans(t *testing.T) {
	reg := New(testLogger())
	model := "rescan-count-model"
	winner := planTestProvider(t, reg, "rescan-winner", model, 0)

	// Large enough that scheduler jitter or a GC pause inside the final,
	// one-provider scan cannot approach it (the assertions below are
	// structural, but the margin keeps RescanUS unambiguous under -race).
	const slowScan = 20 * time.Millisecond
	var scans atomic.Int32
	reg.reservationAfterScan = func(string) {
		if scans.Add(1) != 1 {
			return
		}
		// First scan only: a competing reservation lands on the winner while
		// this scan is still under the shared lock (p.mu only — the canonical
		// r.mu → p.mu order), and the scan is made measurably slow so the
		// discarded iteration's cost is visible.
		winner.AddPending(&PendingRequest{
			RequestID: "rescan-competitor", Model: model,
			EstimatedPromptTokens: 100, RequestedMaxTokens: 100,
		})
		time.Sleep(slowScan)
	}

	pr := planTestRequest("rescan-req", 100, 100)
	pr.Model = model
	p, decision := reg.ReserveProviderEx(model, pr)
	if p == nil {
		t.Fatalf("reservation failed: %+v", decision)
	}
	defer p.RemovePending(pr.RequestID)
	if got := scans.Load(); got != 2 {
		t.Fatalf("scans = %d, want 2 (one rescan after the commit-time debit)", got)
	}
	if decision.Rescans != 1 {
		t.Fatalf("Rescans = %d, want 1", decision.Rescans)
	}
	if decision.RescanUS < slowScan.Microseconds() {
		t.Fatalf("RescanUS = %d, want >= the discarded iteration's %d µs scan", decision.RescanUS, slowScan.Microseconds())
	}
	// Last-iteration semantics: ScanUS describes the committing iteration,
	// so it cannot include the discarded iteration's sleep that RescanUS
	// carries. Structural (ScanUS < RescanUS) rather than a wall-clock bound
	// on the final scan, which a GC pause on a loaded runner could exceed.
	if decision.ScanUS >= decision.RescanUS {
		t.Fatalf("ScanUS = %d >= RescanUS = %d: the committing scan carried the discarded iteration's cost", decision.ScanUS, decision.RescanUS)
	}
	if decision.PendingForModel != 1 {
		t.Fatalf("PendingForModel = %d, want 1 (the committed iteration saw the competitor)", decision.PendingForModel)
	}
}

// TestReserveProviderNoRescanReportsZero: the common path reports zero
// rescans and zero rescan cost.
func TestReserveProviderNoRescanReportsZero(t *testing.T) {
	reg := New(testLogger())
	model := "rescan-zero-model"
	planTestProvider(t, reg, "rescan-only", model, 0)
	pr := planTestRequest("rescan-zero", 100, 100)
	pr.Model = model
	p, decision := reg.ReserveProviderEx(model, pr)
	if p == nil {
		t.Fatalf("reservation failed: %+v", decision)
	}
	defer p.RemovePending(pr.RequestID)
	if decision.Rescans != 0 || decision.RescanUS != 0 {
		t.Fatalf("Rescans/RescanUS = %d/%d, want 0/0", decision.Rescans, decision.RescanUS)
	}
	if reg.FleetWalkCount() != 1 {
		t.Fatalf("FleetWalkCount = %d, want 1 (one scan)", reg.FleetWalkCount())
	}
}

// rescanFixture is one budget-reporting warm provider whose observed decode
// rate and system metrics the tests perturb between scan and commit.
func rescanFixture(t *testing.T, budgetMax int64) (*Registry, *Provider, string) {
	t.Helper()
	reg := New(testLogger())
	model := "rescan-tolerance-model"
	p := makeTokenBudgetProvider(t, reg, "rescan-p", model, 100, 0, budgetMax, 60)
	return reg, p, model
}

func rescanReserveOnce(t *testing.T, reg *Registry, model, id string) (*Provider, RoutingDecision) {
	t.Helper()
	pr := planTestRequest(id, 100, 100)
	pr.Model = model
	p, decision := reg.ReserveProviderEx(model, pr)
	if p != nil {
		t.Cleanup(func() { p.RemovePending(pr.RequestID) })
	}
	return p, decision
}

// TestCommitToleratesHeartbeatNoise pins the near-tie tolerance: a heartbeat
// that moves the winner's cost by less than nearTieCostWindowMs between the
// shared scan and the commit re-check (CPU 0.1→0.2 = 150 ms of healthMs;
// decode EWMA 60→60.5 tok/s; a whole real heartbeat frame) no longer forces
// a fleet re-walk — the selector would have picked the same winner inside
// the window anyway. Before the tolerance the exact float compare rescanned
// on every one of these (2 scans); now each commits on the first (1 scan).
func TestCommitToleratesHeartbeatNoise(t *testing.T) {
	cases := []struct {
		name    string
		perturb func(reg *Registry, p *Provider, model string)
	}{
		{"cpu usage 0.1 -> 0.2", func(_ *Registry, p *Provider, _ string) {
			p.mu.Lock()
			p.SystemMetrics.CPUUsage = 0.2
			p.mu.Unlock()
		}},
		{"observed decode tps 60 -> 60.5", func(_ *Registry, p *Provider, _ string) {
			p.mu.Lock()
			p.BackendCapacity.Slots[0].ObservedDecodeTPS = 60.5
			p.mu.Unlock()
		}},
		{"real heartbeat frame", func(reg *Registry, p *Provider, model string) {
			// Delivered from its own goroutine while the scan is parked under
			// r.mu.RLock (Heartbeat is RLock + p.mu); the hook waits for it.
			active := model
			hb := &protocol.HeartbeatMessage{
				Type:          protocol.TypeHeartbeat,
				Status:        "idle",
				ActiveModel:   &active,
				WarmModels:    []string{model},
				SystemMetrics: protocol.SystemMetrics{MemoryPressure: 0.1, CPUUsage: 0.2, ThermalState: "nominal"},
				BackendCapacity: &protocol.BackendCapacity{
					TotalMemoryGB: 64,
					Slots: []protocol.BackendSlotCapacity{{
						Model: model, State: "running",
						ActiveTokenBudgetMax: 1_000_000, ObservedDecodeTPS: 60.5,
					}},
				},
			}
			done := make(chan struct{})
			go func() {
				defer close(done)
				reg.Heartbeat(p.ID, hb)
			}()
			<-done
		}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			reg, p, model := rescanFixture(t, 1_000_000)
			var scans atomic.Int32
			reg.reservationAfterScan = func(string) {
				if scans.Add(1) == 1 {
					tc.perturb(reg, p, model)
				}
			}
			got, decision := rescanReserveOnce(t, reg, model, "noise-"+tc.name)
			if got == nil {
				t.Fatalf("reservation failed: %+v", decision)
			}
			if scans.Load() != 1 || decision.Rescans != 0 {
				t.Fatalf("scans=%d rescans=%d, want 1/0: sub-window cost noise must not force a re-walk", scans.Load(), decision.Rescans)
			}
		})
	}
}

// TestCommitRescansOnLargeCostMove: a cost move beyond the near-tie window
// (a 400K-token backlog jump ≈ 6.7 s at 60 tok/s) still rescans — the
// ranking may genuinely have changed.
func TestCommitRescansOnLargeCostMove(t *testing.T) {
	reg, p, model := rescanFixture(t, 1_000_000)
	var scans atomic.Int32
	reg.reservationAfterScan = func(string) {
		if scans.Add(1) == 1 {
			p.mu.Lock()
			p.BackendCapacity.Slots[0].ActiveTokenBudgetUsed = 400_000
			p.mu.Unlock()
		}
	}
	got, decision := rescanReserveOnce(t, reg, model, "large-move")
	if got == nil {
		t.Fatalf("reservation failed: %+v", decision)
	}
	if scans.Load() != 2 || decision.Rescans != 1 {
		t.Fatalf("scans=%d rescans=%d, want 2/1: a cost move beyond the window must rescan", scans.Load(), decision.Rescans)
	}
}

// TestCommitRescanLoopBounded pins the bound: a winner whose debit changes on
// EVERY scan (a competitor lands between each scan and commit) is re-walked
// at most maxCommitRescans times, then committed on revalidated fresh state.
// With the token budget sized for exactly K requests the forced commit admits
// the K-th request and never a (K+1)-th: the budget check runs on fresh state
// regardless of force.
func TestCommitRescanLoopBounded(t *testing.T) {
	const perRequest = 200 // prompt 100 + max 100
	// One competitor lands on the winner during each of the first four scans
	// (the initial scan plus maxCommitRescans rescans); later scans — after
	// a rejected forced commit excluded the provider — add nothing, so the
	// pending set never holds more than four competitors.
	competitor := func(reg *Registry, p *Provider, model string) *atomic.Int32 {
		var scans atomic.Int32
		reg.reservationAfterScan = func(string) {
			n := scans.Add(1)
			if n > maxCommitRescans+1 {
				return
			}
			p.AddPending(&PendingRequest{
				RequestID: fmt.Sprintf("competitor-%d", n), Model: model,
				EstimatedPromptTokens: 100, RequestedMaxTokens: 100,
			})
		}
		return &scans
	}

	t.Run("bounded and admitted within budget", func(t *testing.T) {
		// K = 5: four competitors (one per scan: initial + 3 rescans) + this one.
		reg, p, model := rescanFixture(t, 5*perRequest)
		scans := competitor(reg, p, model)
		got, decision := rescanReserveOnce(t, reg, model, "bounded")
		if got == nil {
			t.Fatalf("reservation failed after the rescan bound: %+v", decision)
		}
		if scans.Load() != maxCommitRescans+1 || decision.Rescans != maxCommitRescans {
			t.Fatalf("scans=%d rescans=%d, want %d/%d", scans.Load(), decision.Rescans, maxCommitRescans+1, maxCommitRescans)
		}
		if n := p.PendingCount(); n != 5 {
			t.Fatalf("pending=%d, want 5 (4 competitors + the forced commit)", n)
		}
	})

	t.Run("forced commit cannot double-spend", func(t *testing.T) {
		// K = 4: the four competitors exhaust the budget before the forced
		// commit, which must be REJECTED by the fresh-state budget check and
		// never admit a fifth request.
		reg, p, model := rescanFixture(t, 4*perRequest)
		scans := competitor(reg, p, model)
		got, decision := rescanReserveOnce(t, reg, model, "double-spend")
		if got != nil {
			t.Fatalf("forced commit admitted a request beyond the budget (pending=%d)", p.PendingCount())
		}
		if scans.Load() < maxCommitRescans+1 {
			t.Fatalf("scans=%d, want >= %d before the forced commit", scans.Load(), maxCommitRescans+1)
		}
		if decision.CapacityRejections == 0 {
			t.Fatalf("decision should report the budget rejection: %+v", decision)
		}
		if n := p.PendingCount(); n != 4 {
			t.Fatalf("pending=%d, want exactly the 4 competitors (K): the forced commit must not add a fifth", n)
		}
		if p.GetPending("double-spend") != nil {
			t.Fatal("the rejected request is still in the pending set")
		}
	})
}

// TestForcedCommitStillRevalidatesAdmission calls the commit phase directly
// with force=true on a scan taken BEFORE the budget filled: the stale winner
// must be rejected (reservationCandidateRejected), and the same forced commit
// with headroom must succeed — force skips the ranking-drift comparison only.
func TestForcedCommitStillRevalidatesAdmission(t *testing.T) {
	const perRequest = 200
	reg, p, model := rescanFixture(t, 3*perRequest)
	pr := planTestRequest("forced-direct", 100, 100)
	pr.Model = model
	scan := reg.scanProviderReservation(model, pr)
	if scan.selected == nil {
		t.Fatal("scan found no candidate")
	}
	// Fill the budget after the scan: three requests, no room for a fourth.
	for i := range 3 {
		p.AddPending(&PendingRequest{RequestID: fmt.Sprintf("fill-%d", i), Model: model, EstimatedPromptTokens: 100, RequestedMaxTokens: 100})
	}
	if _, _, outcome, _ := reg.commitProviderReservation(model, pr, scan, true); outcome != reservationCandidateRejected {
		t.Fatalf("forced commit on an exhausted budget: outcome=%v, want reservationCandidateRejected", outcome)
	}
	if n := p.PendingCount(); n != 3 {
		t.Fatalf("pending=%d after rejected forced commit, want 3", n)
	}
	// Control: with headroom the same forced commit lands.
	p.RemovePending("fill-0")
	if _, _, outcome, _ := reg.commitProviderReservation(model, pr, scan, true); outcome != reservationCommitted {
		t.Fatalf("forced commit with headroom: outcome=%v, want reservationCommitted", outcome)
	}
	p.RemovePending(pr.RequestID)
}
