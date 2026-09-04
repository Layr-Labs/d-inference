package registry

import (
	"sync/atomic"
	"testing"
	"time"
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

	const slowScan = 3 * time.Millisecond
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
	// Last-iteration semantics: the committing scan was fast, so ScanUS must
	// not carry the discarded iteration's sleep.
	if decision.ScanUS >= slowScan.Microseconds() {
		t.Fatalf("ScanUS = %d, want the final iteration's (< %d µs)", decision.ScanUS, slowScan.Microseconds())
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
