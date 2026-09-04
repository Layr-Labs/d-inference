package registry

import (
	"testing"
)

// The TTFT shadow evaluator reuses the scan that selected the winner instead
// of re-walking the fleet after every busy-winner commit. These tests pin
// (1) that the idle-alternative bit from the winning scan equals what the
// post-commit rescan used to compute on every fixture shape, and (2) that a
// shadow-mode reservation onto a herded winner performs exactly one fleet
// walk (it performed two).

// shadowScanFixture registers a herded fast winner (occupancy 1, 300 tok/s)
// plus the peers the case asks for, and returns the request the winner is
// reserved for.
func shadowScanFixture(t *testing.T, reg *Registry, model string, idlePeer, busyPeer bool) *PendingRequest {
	t.Helper()
	fastBusy := makeSchedulerProvider(t, reg, "fast-busy", model, 300)
	fastBusy.mu.Lock()
	fastBusy.BackendCapacity.Slots[0].NumRunning = 1
	fastBusy.mu.Unlock()
	if idlePeer {
		makeSchedulerProvider(t, reg, "slow-idle", model, 20)
	}
	if busyPeer {
		slowBusy := makeSchedulerProvider(t, reg, "slow-busy", model, 20)
		slowBusy.mu.Lock()
		slowBusy.BackendCapacity.Slots[0].NumRunning = 2
		slowBusy.mu.Unlock()
	}
	return &PendingRequest{RequestID: "shadow-scan-req", Model: model, EstimatedPromptTokens: 100, RequestedMaxTokens: 256}
}

// TestShadowIdleAlternativeMatchesRescan: on fixtures with an idle warm peer,
// a busy-only peer, and the winner alone, the bit derived from the winning
// scan equals the former post-commit rescan (loadedIdleAlternativeExistsLocked
// over the same request and exclusions, evaluated after the commit).
func TestShadowIdleAlternativeMatchesRescan(t *testing.T) {
	withTTFTConfig(t, 0, defaultTTFTDeadlineBaseMs, TTFTAdmissionShadow)
	cases := []struct {
		name               string
		idlePeer, busyPeer bool
		want               bool
	}{
		{"idle warm peer", true, false, true},
		{"busy peer only", false, true, false},
		{"winner only", false, false, false},
		{"idle and busy peers", true, true, true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			reg := New(testLogger())
			model := "shadow-scan-model"
			pr := shadowScanFixture(t, reg, model, tc.idlePeer, tc.busyPeer)
			winner, decision := reg.ReserveProviderEx(model, pr)
			if winner == nil || winner.ID != "fast-busy" {
				t.Fatalf("winner=%v, want the herded fast box: %+v", winner, decision)
			}
			defer winner.RemovePending(pr.RequestID)
			if !decision.ShadowEvaluated || decision.ShadowOccupancy != 1 {
				t.Fatalf("shadow not evaluated on the herded winner: %+v", decision)
			}
			// The former rescan semantics, computed the old way after the commit.
			reg.mu.RLock()
			rescanned := reg.loadedIdleAlternativeExistsLocked(model, pr, winner)
			reg.mu.RUnlock()
			if decision.ShadowIdleAlternativeExists != tc.want || rescanned != tc.want {
				t.Fatalf("ShadowIdleAlternativeExists=%v rescan=%v, want %v", decision.ShadowIdleAlternativeExists, rescanned, tc.want)
			}
		})
	}
}

// TestShadowEvaluationDoesNotRewalkTheFleet: a shadow-mode reservation whose
// winner is herded (occupancy > 0) walks the fleet exactly once — the scan
// that selected the winner. Before, the evaluator took r.mu.RLock and ran a
// second scanCandidatesLocked solely for the idle-alternative bit.
func TestShadowEvaluationDoesNotRewalkTheFleet(t *testing.T) {
	withTTFTConfig(t, 0, defaultTTFTDeadlineBaseMs, TTFTAdmissionShadow)
	reg := New(testLogger())
	model := "shadow-walks-model"
	pr := shadowScanFixture(t, reg, model, true, false)
	before := reg.FleetWalkCount()
	winner, decision := reg.ReserveProviderEx(model, pr)
	if winner == nil {
		t.Fatalf("reservation failed: %+v", decision)
	}
	defer winner.RemovePending(pr.RequestID)
	if decision.ShadowOccupancy == 0 || !decision.ShadowIdleAlternativeExists {
		t.Fatalf("precondition: herded winner with an idle peer, got %+v", decision)
	}
	if walks := reg.FleetWalkCount() - before; walks != 1 {
		t.Fatalf("fleet walks per shadow-mode reserve = %d, want 1 (the selecting scan only)", walks)
	}
}
