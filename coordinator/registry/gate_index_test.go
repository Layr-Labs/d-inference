package registry

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
)

// Tests for the gate index (gate_index.go): session → gate resolution through
// the disconnect cache, nil-safety of the scan's gate reads, and the routing
// read path confirming its view against p.gate across a shared-identity
// rebind (gateView).

// The trailing pending-request flush runs after Disconnect removed the session:
// its faults must still resolve to the stable identity's gate through the
// disconnect cache, exactly as the map-keyed faultKeyLocked fallback did.
func TestDisconnectedTrailingFlushResolvesIdentityGate(t *testing.T) {
	reg := New(testLogger())
	p := attestSchedulerProvider(t, reg, "sess-flush", "m", "SER-FLUSH", 100)
	reg.Disconnect(p.ID)
	if got := reg.faultKeyForSession(p.ID); got != "serial:SER-FLUSH" {
		t.Fatalf("post-disconnect fault key = %q, want the cached identity", got)
	}
	for i := 0; i < providerBreakerConsecTrip; i++ {
		reg.RecordProviderOutcome(p.ID, false, 502, "provider disconnected")
	}
	if !gateHasBreakerWindow(reg, "serial:SER-FLUSH") || rawGateForKey(reg, p.ID) != nil {
		t.Fatal("trailing-flush faults must land on the identity's gate, not a session gate")
	}
	if !reg.ProviderBreakerOpen(p.ID) {
		t.Fatal("the identity's breaker must be open via the disconnected session id")
	}
}

// Gate reads on a Provider that was never registered (bare test objects) and
// on a nil gate are "no state", never a panic.
func TestGateReadsAreNilSafe(t *testing.T) {
	reg := New(testLogger())
	bare := &Provider{ID: "bare"}
	g := reg.gateOf(bare)
	now := time.Now()
	if g != nil {
		t.Fatalf("bare provider resolved to a gate: %+v", g)
	}
	if g.breakerOpenAt(now.UnixNano()) || g.ejectedAt(now.UnixNano()) || g.dispatchLoadCooled("m", now) ||
		g.inferenceErrorCooled("m", "base", now) || g.capacityCooled("m", now) ||
		g.budgetClampActive(reg.budgetClampCfg, "m", now, 0, false, now) {
		t.Fatal("a nil gate must read as no state")
	}
	if pen, rate := g.capacityRatePenalty(reg.capacityRateCfg, "m", now); pen != 0 || rate != 0 {
		t.Fatal("a nil gate must carry no rate penalty")
	}
	if !reg.tryClaimCapacityProbe(bare, "m", now) || !reg.tryClaimCapacityProbe(nil, "m", now) {
		t.Fatal("a provider with no gate must admit the probe claim")
	}
	if reg.ejectionOpenFor(g, "serial:none", now.UnixNano()) {
		t.Fatal("an unknown identity must not read as ejected")
	}
}

// A routing scan that loaded a session's gate just before the session rebound
// away from a SHARED identity must not trust what it reads there: the
// migration moves the state to the session's new gate and resets the shared
// source — now the sibling's alone — to zeros, so an unconfirmed read admits
// the session past the breaker or cooldown that moved with it.
// gateStateReasonLocked confirms the verdict against p.gate and re-reads from
// the new gate. The sibling's view, loaded at the same moment, stays put and
// reads its identity's (now empty) state: a rebind never makes the OTHER
// session look faulty. Both read kinds are covered — the breaker (an atomic)
// and the dispatch-load cooldown (a per-model map under gate.mu) — in both
// commit modes: the scan's gate and the commit's admit re-check are the same
// function, and the end-to-end reservation must never land on the rebound
// session.
func TestScanRevalidatesGateAcrossSharedRebind(t *testing.T) {
	const model = "m"
	cases := []struct {
		name   string
		fault  func(reg *Registry, sessionID string)
		read   func(g *gateState, now time.Time) bool // the unconfirmed read the scan used to make
		reason GateReason
	}{
		{
			name: "breaker",
			fault: func(reg *Registry, id string) {
				for i := 0; i < providerBreakerConsecTrip; i++ {
					reg.RecordProviderOutcome(id, false, 500, "internal error")
				}
			},
			read:   func(g *gateState, now time.Time) bool { return g.breakerOpenAt(now.UnixNano()) },
			reason: GateBreaker,
		},
		{
			name:   "dispatch-load cooldown",
			fault:  func(reg *Registry, id string) { reg.RecordDispatchLoadFailure(id, model) },
			read:   func(g *gateState, now time.Time) bool { return g.dispatchLoadCooled(model, now) },
			reason: GateDispatchLoadCooldown,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			forEachCommitMode(t, func(t *testing.T, mode reserveCommitMode) {
				reg := New(testLogger())
				setReserveCommitModeForTest(reg, mode)
				p1 := makeSchedulerProvider(t, reg, "sess-view-1", model, 100)
				p2 := makeSchedulerProvider(t, reg, "sess-view-2", model, 100)
				pk := &attestation.VerificationResult{Valid: true, PublicKey: "PK-VIEW"}
				p1.SetAttestationResult(pk)
				p2.SetAttestationResult(pk)
				shared := reg.lookupGateForKey("sekey:PK-VIEW")
				if shared == nil || p1.gate.Load() != shared || p2.gate.Load() != shared {
					t.Fatal("both sessions must share the identity's gate")
				}
				tc.fault(reg, p1.ID)
				now := time.Now()
				// The scan's gate evaluation on an already-loaded view, under
				// p.mu as the scan holds it.
				verdict := func(view *gateView) (ok bool, reason GateReason) {
					view.p.mu.Lock()
					defer view.p.mu.Unlock()
					return reg.gateStateReasonLocked(view, model, RequestTraits{}, now, false, false)
				}
				// Precondition: the identity's fault gates both sessions.
				for _, p := range []*Provider{p1, p2} {
					view := reg.gateViewOf(p)
					if ok, reason := verdict(&view); ok || reason != tc.reason {
						t.Fatalf("pre-rebind verdict for %s = (%v, %v), want gated by %v", p.ID, ok, reason, tc.reason)
					}
				}

				// Two scans load the shared gate, one per session...
				view1, view2 := reg.gateViewOf(p1), reg.gateViewOf(p2)
				if view1.g != shared || view2.g != shared {
					t.Fatalf("views = %+v / %+v, want the shared gate", view1, view2)
				}
				// ...and p1 enriches to a serial before either reads it.
				p1.SetAttestationResult(&attestation.VerificationResult{Valid: true, PublicKey: "PK-VIEW", SerialNumber: "SER-VIEW"})
				target := p1.gate.Load()
				if target == shared || target.key != "serial:SER-VIEW" || p2.gate.Load() != shared {
					t.Fatalf("after the rebind p1 → %+v, p2 → %+v; want p1 on serial:SER-VIEW and p2 unmoved", target, p2.gate.Load())
				}
				// The race: the gate the scan holds now reads clean — the state
				// moved with p1 and the shared source was reset for p2.
				if tc.read(shared, now) || !tc.read(target, now) {
					t.Fatalf("precondition: the %s must have moved from the shared gate to p1's new gate", tc.name)
				}

				// p1's scan must not admit p1: the view is confirmed against
				// p.gate, found moved, and re-read from the new gate.
				if ok, reason := verdict(&view1); ok || reason != tc.reason {
					t.Fatalf("p1's stale view verdict = (%v, %v), want gated by %v", ok, reason, tc.reason)
				}
				if view1.g != target || view1.rereads != 1 {
					t.Fatalf("p1's view after the verdict = %+v, want rebased on serial:SER-VIEW after one re-read", view1)
				}
				// p2's scan reads its own identity, which now has nothing: not
				// gated, and the view did not move.
				if ok, reason := verdict(&view2); !ok || reason != GateReasonCount {
					t.Fatalf("p2's view verdict = (%v, %v), want not gated — a rebind must not make the other session look faulty", ok, reason)
				}
				if view2.g != shared || view2.rereads != 0 {
					t.Fatalf("p2's view after the verdict = %+v, want the shared gate, unmoved", view2)
				}

				// End to end, in this commit mode: the reservation must never
				// land on p1 (its fault lives on its new gate); p2's identity is
				// clean and takes the request.
				pr := &PendingRequest{
					RequestID:             "view-" + mode.String() + "-" + tc.name,
					Model:                 model,
					EstimatedPromptTokens: 200,
					RequestedMaxTokens:    128,
					FirstContentBudgetMS:  10_000,
					FirstContentDeadline:  time.Now().Add(10 * time.Second),
				}
				got, _ := reg.ReserveProviderEx(model, pr)
				if got == p1 {
					t.Fatal("the reservation landed on the rebound session past the fault that moved with it")
				}
				if got != p2 {
					t.Fatalf("reservation = %v, want p2 (the sibling's identity carries no state after the move)", got)
				}
			})
		})
	}
}
