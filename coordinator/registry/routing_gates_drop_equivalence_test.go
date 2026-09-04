package registry

import (
	"fmt"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/attestation"
)

// Drop-path equivalence for scanCandidatesLocked's fail-open and transient-
// capacity tallies. The scan used to run the breaker lookup, a p.mu identity
// read + ejection lookup, and a capacity-cooldown lookup + full gate re-run
// for EVERY dropped provider; it now keys those on the closed GateReason
// (first failing gate) and skips them for providers dropped by a gate that
// runs after the breaker/ejection/capacity-cooldown gates. This test
// enumerates the inducible drop reasons × every combination of breaker-open,
// ejected and capacity-cooled state, and asserts the tallies equal the
// old rule computed independently from the state:
//
//	breakerRejected   = breakerOpen || (!breakerOpen && ejected)   (normal pass)
//	capacityRejection = cooled && passes every gate except the cooldown
//
// so the fail-open valve and the over_capacity classification are unchanged.

type dropReasonCase struct {
	name string
	// apply induces the reason on the provider (after the fixture is built).
	apply func(t *testing.T, reg *Registry, p *Provider, model string, pr *PendingRequest)
	// gateDrop reports whether the reason is a routing-gate drop (which the
	// old capacity re-check "otherwise routable" predicate ran against) as
	// opposed to a buildCandidate drop that the gate re-check does not see.
	gateDrop bool
}

func dropEquivalenceProvider(t *testing.T, reg *Registry, model string) *Provider {
	t.Helper()
	p := makeTokenBudgetProvider(t, reg, "drop-eq", model, 100, 0, 10_000, 80)
	p.SetAttestationResult(&attestation.VerificationResult{Valid: true, SerialNumber: "DROP-EQ"})
	return p
}

func TestScanDropPathTalliesMatchOldRule(t *testing.T) {
	reasons := []dropReasonCase{
		{"none", func(*testing.T, *Registry, *Provider, string, *PendingRequest) {}, false},
		{"dispatch_load_cooldown", func(_ *testing.T, reg *Registry, p *Provider, model string, _ *PendingRequest) {
			reg.RecordDispatchLoadFailure(p.ID, model)
		}, true},
		{"error_cooldown", func(_ *testing.T, reg *Registry, p *Provider, model string, _ *PendingRequest) {
			reg.RecordInferenceError(p.ID, model, 500, "base")
			reg.RecordInferenceError(p.ID, model, 500, "base")
		}, true},
		{"offline", func(_ *testing.T, _ *Registry, p *Provider, _ string, _ *PendingRequest) {
			p.mu.Lock()
			p.Status = StatusOffline
			p.mu.Unlock()
		}, true},
		{"slot_crashed", func(_ *testing.T, _ *Registry, p *Provider, _ string, _ *PendingRequest) {
			p.mu.Lock()
			p.BackendCapacity.Slots[0].State = "crashed"
			p.mu.Unlock()
		}, false},
		{"free_memory", func(_ *testing.T, _ *Registry, p *Provider, _ string, _ *PendingRequest) {
			p.mu.Lock()
			p.BackendCapacity.Slots[0].ActiveTokenBudgetUsed = 9_990
			p.mu.Unlock()
		}, false},
		{"ttft_ceiling", func(_ *testing.T, _ *Registry, _ *Provider, _ string, pr *PendingRequest) {
			pr.MaxTTFTMs = 1
		}, false},
	}
	states := []struct {
		breakerOpen, ejected, cooled bool
	}{}
	for _, b := range []bool{false, true} {
		for _, e := range []bool{false, true} {
			for _, c := range []bool{false, true} {
				states = append(states, struct{ breakerOpen, ejected, cooled bool }{b, e, c})
			}
		}
	}

	for _, rc := range reasons {
		for _, st := range states {
			name := fmt.Sprintf("%s/breaker=%v/ejected=%v/cooled=%v", rc.name, st.breakerOpen, st.ejected, st.cooled)
			t.Run(name, func(t *testing.T) {
				reg := New(testLogger())
				model := "drop-eq-model"
				p := dropEquivalenceProvider(t, reg, model)
				pr := planTestRequest("drop-eq-req", 100, 100)
				pr.Model = model
				rc.apply(t, reg, p, model, pr)
				if st.breakerOpen {
					for i := 0; i < providerBreakerConsecTrip; i++ {
						reg.RecordProviderOutcome(p.ID, false, 500, "boom")
					}
				}
				if st.ejected {
					for i := 0; i < healthEjectionConsecTrip; i++ {
						reg.RecordProviderServeOutcome("serial:DROP-EQ", false, 500, "boom")
					}
				}
				if st.cooled {
					for i := 0; i < defaultCapacityCooldownThreshold; i++ {
						reg.RecordCapacityReject(p.ID, model)
					}
				}

				// Old rule, from the state alone. The gate chain (dispatch-load →
				// error cooldown → capacity cooldown → breaker → ejection →
				// liveness) drops the provider when ANY of those states holds;
				// the old tallies then depended only on the state, never on
				// which gate fired first. A provider that passes every gate
				// reaches buildCandidate, whose drops carry their own tallies.
				gateDrop := rc.gateDrop || st.breakerOpen || st.ejected || st.cooled
				wantBreaker, wantCapacity, wantTTFT, wantCandidates := 0, 0, 0, 0
				if gateDrop {
					if st.breakerOpen || st.ejected {
						wantBreaker = 1
					}
					if st.cooled && !rc.gateDrop && !st.breakerOpen && !st.ejected {
						wantCapacity = 1 // cooled and otherwise routable: transient capacity
					}
				} else {
					switch rc.name {
					case "none":
						wantCandidates = 1
					case "free_memory":
						wantCapacity = 1
					case "ttft_ceiling":
						wantTTFT = 1
					}
				}

				reg.mu.RLock()
				scan := reg.scanCandidatesLocked(model, pr, false)
				reg.mu.RUnlock()
				if scan.breakerRejected != wantBreaker || scan.capacityRejections != wantCapacity ||
					scan.ttftRejections != wantTTFT || scan.candidateCount != wantCandidates {
					t.Fatalf("breaker=%d capacity=%d ttft=%d candidates=%d, want %d/%d/%d/%d (gates=%v)",
						scan.breakerRejected, scan.capacityRejections, scan.ttftRejections, scan.candidateCount,
						wantBreaker, wantCapacity, wantTTFT, wantCandidates, scan.gateRejections)
				}
				// The fail-open valve reads exactly these tallies, so its verdict
				// is unchanged whenever they are.
				if got, want := shouldBypassBreakerFailOpen(nil, scan.breakerRejected, scan.capacityRejections, scan.ttftRejections),
					shouldBypassBreakerFailOpen(nil, wantBreaker, wantCapacity, wantTTFT); got != want {
					t.Fatalf("fail-open bypass=%v, want %v", got, want)
				}
			})
		}
	}
}

// TestQuickCapacityCheckCooledPairCountsAsTransientCapacity mirrors the
// reason-keyed form in the preflight: a pair dropped by the capacity cooldown
// alone counts as a capacity rejection; one that also fails a structural gate
// (offline) or an earlier cooldown does not.
func TestQuickCapacityCheckCooledPairCountsAsTransientCapacity(t *testing.T) {
	cases := []struct {
		name         string
		also         func(reg *Registry, p *Provider, model string)
		wantCapacity int
	}{
		{"cooled only", func(*Registry, *Provider, string) {}, 1},
		{"cooled and offline", func(_ *Registry, p *Provider, _ string) {
			p.mu.Lock()
			p.Status = StatusOffline
			p.mu.Unlock()
		}, 0},
		{"cooled and dispatch-load cooling", func(reg *Registry, p *Provider, model string) {
			reg.RecordDispatchLoadFailure(p.ID, model)
		}, 0},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			reg := New(testLogger())
			model := "quick-cooled-model"
			p := dropEquivalenceProvider(t, reg, model)
			for i := 0; i < defaultCapacityCooldownThreshold; i++ {
				reg.RecordCapacityReject(p.ID, model)
			}
			tc.also(reg, p, model)
			candidates, capacityRejections, tooLarge := reg.QuickCapacityCheckForRequest(model, 100, 100, RequestTraits{}, false)
			if candidates != 0 || tooLarge != 0 || capacityRejections != tc.wantCapacity {
				t.Fatalf("candidates=%d capacity=%d tooLarge=%d, want 0/%d/0", candidates, capacityRejections, tooLarge, tc.wantCapacity)
			}
		})
	}
}
