package registry_test

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/identitygate"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

// The trailing pending-request flush runs after Disconnect removed the session:
// its faults must still resolve to the stable identity's gate through the
// disconnect cache, exactly as the map-keyed faultKeyLocked fallback did.
func TestDisconnectedTrailingFlushResolvesIdentityGate(t *testing.T) {
	gates := identitygate.New(testLogger(), nil)
	reg := production.NewWithDependencies(testLogger(), production.Dependencies{IdentityGates: gates})
	p := attestSchedulerProvider(t, reg, "sess-flush", "m", "SER-FLUSH", 100)
	reg.Disconnect(p.ID)
	if got := gates.FaultKeyForSession(p.ID); got != "serial:SER-FLUSH" {
		t.Fatalf("post-disconnect fault key = %q, want the cached identity", got)
	}
	for i := 0; i < providerBreakerConsecTrip; i++ {
		reg.RecordProviderOutcome(p.ID, false, 502, "provider disconnected")
	}
	if !gates.ViewIdentity("serial:SER-FLUSH").BreakerHealth(time.Now()).HasHistory || gates.ViewIdentity(p.ID).Present() {
		t.Fatal("trailing-flush faults must land on the identity's gate, not a session gate")
	}
	if !reg.ProviderBreakerOpen(p.ID) {
		t.Fatal("the identity's breaker must be open via the disconnected session id")
	}
}

// Gate reads on a Provider that was never registered (bare test objects) and
// on a nil gate are "no state", never a panic.
func TestGateReadsAreNilSafe(t *testing.T) {
	gates := identitygate.New(testLogger(), nil)
	bare := &production.Provider{ID: "bare"}
	g := gates.ViewForSession(nil, bare.ID)
	now := time.Now()
	if g.Present() {
		t.Fatalf("bare provider resolved to a gate: %+v", g)
	}
	if g.BreakerOpenAt(now.UnixNano()) || g.EjectedAt(now.UnixNano()) || g.DispatchLoadCooled("m", now) ||
		g.InferenceErrorCooled("m", "base", now) || g.CapacityCooled("m", now) ||
		g.BudgetClampActive("m", now, 0, false, now) {
		t.Fatal("a nil gate must read as no state")
	}
	if pen, rate := g.CapacityRatePenalty("m", now); pen != 0 || rate != 0 {
		t.Fatal("a nil gate must carry no rate penalty")
	}
	if !gates.ClaimCapacityProbe(gates.ReferenceForSession(nil, bare.ID), "m", now) || !gates.ClaimCapacityProbe(identitygate.Reference{}, "m", now) {
		t.Fatal("a provider with no gate must admit the probe claim")
	}
	if g.EjectionOpenFor("serial:none", now.UnixNano()) {
		t.Fatal("an unknown identity must not read as ejected")
	}
}

// A routing scan that loaded a session's gate just before the session rebound
// away from a SHARED identity must not trust what it reads there: the
// migration moves the state to the session's new gate and resets the shared
// source, now the sibling's alone, to zeros, so an unconfirmed read admits
// the session past the breaker or cooldown that moved with it.
// Evaluate confirms the verdict against the session and re-reads from the
// new gate. The sibling's view, loaded at the same moment, stays put and
// reads its identity's (now empty) state: a rebind never makes the OTHER
// session look faulty. Both read kinds are covered, the breaker (an atomic)
// and the dispatch-load cooldown (a per-model map under the gate lock), in
// both commit modes: the scan's gate and the commit's admit re-check use the
// same evaluation, and the end-to-end reservation must never land on the
// rebound session.
func TestScanRevalidatesGateAcrossSharedRebind(t *testing.T) {
	const model = "m"
	cases := []struct {
		name   string
		fault  func(reg *production.Registry, sessionID string)
		read   func(g identitygate.View, now time.Time) bool // the unconfirmed read the scan used to make
		reason identitygate.Reason
	}{
		{
			name: "breaker",
			fault: func(reg *production.Registry, id string) {
				for i := 0; i < providerBreakerConsecTrip; i++ {
					reg.RecordProviderOutcome(id, false, 500, "internal error")
				}
			},
			read:   func(g identitygate.View, now time.Time) bool { return g.BreakerOpenAt(now.UnixNano()) },
			reason: identitygate.ProviderBreaker,
		},
		{
			name:   "dispatch-load cooldown",
			fault:  func(reg *production.Registry, id string) { reg.RecordDispatchLoadFailure(id, model) },
			read:   func(g identitygate.View, now time.Time) bool { return g.DispatchLoadCooled(model, now) },
			reason: identitygate.DispatchLoadCooldown,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			forEachCommitMode(t, func(t *testing.T, mode string) {
				t.Setenv("EIGENINFERENCE_RESERVE_COMMIT_MODE", mode)
				gates := identitygate.New(testLogger(), nil)
				reg := production.NewWithDependencies(testLogger(), production.Dependencies{IdentityGates: gates})
				p1 := makeSchedulerProvider(t, reg, "sess-view-1", model, 100)
				p2 := makeSchedulerProvider(t, reg, "sess-view-2", model, 100)
				pk := &attestation.VerificationResult{Valid: true, PublicKey: "PK-VIEW"}
				p1.SetAttestationResult(pk)
				p2.SetAttestationResult(pk)
				shared := gates.ViewIdentity("sekey:PK-VIEW")
				if !shared.Present() || !gates.ViewReference(gates.ResolveSession(p1.ID, false)).SameIdentity(shared) || !gates.ViewReference(gates.ResolveSession(p2.ID, false)).SameIdentity(shared) {
					t.Fatal("both sessions must share the identity's gate")
				}
				tc.fault(reg, p1.ID)
				now := time.Now()
				// The scan's gate evaluation on an already-loaded view, under
				// p.mu as the scan holds it.
				verdict := func(p *production.Provider, view *identitygate.View) (ok bool, reason identitygate.Reason, rereads int) {
					p.Mu().Lock()
					defer p.Mu().Unlock()
					decision := view.Evaluate(model, (production.RequestTraits{}).CooldownShape(), func() string {
						return gates.FaultKeyForSession(p.ID)
					}, now, false, false)
					return decision.Reason == identitygate.Allowed, decision.Reason, decision.Rereads
				}
				// Precondition: the identity's fault gates both sessions.
				for _, p := range []*production.Provider{p1, p2} {
					view := gates.ViewReference(gates.ResolveSession(p.ID, false))
					if ok, reason, _ := verdict(p, &view); ok || reason != tc.reason {
						t.Fatalf("pre-rebind verdict for %s = (%v, %v), want gated by %v", p.ID, ok, reason, tc.reason)
					}
				}

				// Two scans load the shared gate, one per session...
				view1 := gates.ViewReference(gates.ResolveSession(p1.ID, false))
				view2 := gates.ViewReference(gates.ResolveSession(p2.ID, false))
				if !view1.SameIdentity(shared) || !view2.SameIdentity(shared) {
					t.Fatalf("views = %+v / %+v, want the shared gate", view1, view2)
				}
				// ...and p1 enriches to a serial before either reads it.
				p1.SetAttestationResult(&attestation.VerificationResult{Valid: true, PublicKey: "PK-VIEW", SerialNumber: "SER-VIEW"})
				target := gates.ViewReference(gates.ResolveSession(p1.ID, false))
				if target.SameIdentity(shared) || !target.SameIdentity(gates.ViewIdentity("serial:SER-VIEW")) || !gates.ViewReference(gates.ResolveSession(p2.ID, false)).SameIdentity(shared) {
					t.Fatalf("after the rebind p1 → %+v, p2 → %+v; want p1 on serial:SER-VIEW and p2 unmoved", target, gates.ViewReference(gates.ResolveSession(p2.ID, false)))
				}
				// The race: the gate the scan holds now reads clean, because the
				// state moved with p1 and the shared source was reset for p2.
				if tc.read(shared, now) || !tc.read(target, now) {
					t.Fatalf("precondition: the %s must have moved from the shared gate to p1's new gate", tc.name)
				}

				// p1's scan must not admit p1: the view is confirmed against
				// its session, found moved, and re-read from the new gate.
				ok, reason, rereads := verdict(p1, &view1)
				if ok || reason != tc.reason {
					t.Fatalf("p1's stale view verdict = (%v, %v), want gated by %v", ok, reason, tc.reason)
				}
				if !view1.SameIdentity(target) || rereads != 1 {
					t.Fatalf("p1's view after the verdict = %+v, want rebased on serial:SER-VIEW after one re-read", view1)
				}
				// p2's scan reads its own identity, which now has nothing: not
				// gated, and the view did not move.
				ok, reason, rereads = verdict(p2, &view2)
				if !ok || reason != identitygate.Allowed {
					t.Fatalf("p2's view verdict = (%v, %v), want not gated — a rebind must not make the other session look faulty", ok, reason)
				}
				if !view2.SameIdentity(shared) || rereads != 0 {
					t.Fatalf("p2's view after the verdict = %+v, want the shared gate, unmoved", view2)
				}

				// End to end, in this commit mode: the reservation must never
				// land on p1 (its fault lives on its new gate); p2's identity is
				// clean and takes the request.
				pr := &production.PendingRequest{
					RequestID:             "view-" + mode + "-" + tc.name,
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
