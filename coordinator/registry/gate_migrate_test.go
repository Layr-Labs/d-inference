package registry

import (
	"runtime"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
)

// Tests for the identity migration (gate_migrate.go): stale cached pointers
// follow the forward, lock-free readers never see an empty gate mid-rebind,
// and a shared identity gate stays in the index for its other sessions.

// A recorder that resolved the session's gate just before attestation bound
// the stable identity must land its outcome on the identity's gate, not on
// the orphaned session gate: lockGate follows the forward set by the
// migration, and the orphan is gone from the index.
func TestStaleGatePointerFollowsIdentityMigration(t *testing.T) {
	reg := New(testLogger())
	p := makeSchedulerProvider(t, reg, "sess-stale", "m", 100)
	ref := reg.gateForSession(p.ID)
	stale := ref.g
	if stale == nil || stale.key != p.ID {
		t.Fatalf("pre-bind gate = %+v, want the session-keyed gate", stale)
	}

	p.SetAttestationResult(&attestation.VerificationResult{Valid: true, SerialNumber: "SER-STALE"})
	target := reg.lookupGateForKey("serial:SER-STALE")
	if target == nil || target.key != "serial:SER-STALE" {
		t.Fatalf("bind did not file the identity's gate: %+v", target)
	}
	if rawGateForKey(reg, p.ID) != nil {
		t.Fatal("the orphaned session gate must leave the index")
	}
	if stale.resolve() != target {
		t.Fatal("resolve() on the stale pointer must follow the migration forward")
	}
	hold := reg.lockGate(ref, "test")
	if hold.g != target {
		hold.unlock()
		t.Fatal("lockGate on the stale pointer must lock the live gate")
	}
	hold.g.breakerTrips++
	hold.g.updatedLocked(time.Now())
	hold.unlock()
	if got := providerBreakerTripsOf(reg, p.ID); got != 1 {
		t.Fatalf("mutation through the stale pointer landed elsewhere: trips=%d", got)
	}
	if p.gate.Load() != target {
		t.Fatal("the provider's cached gate must point at the identity's gate")
	}
}

// During a live re-attestation that changes the identity, a lock-free reader
// must never see the identity's fault state vanish: the orphaned session gate
// keeps its (conservative) atomics — it is never republished after the reset
// — and the provider's cached pointer is repointed only once the target
// carries the merged state.
func TestMigrationNeverExposesAnEmptyGateToLockFreeReaders(t *testing.T) {
	reg := New(testLogger())
	p := makeSchedulerProvider(t, reg, "sess-mig-view", "m", 100)
	for i := 0; i < providerBreakerConsecTrip; i++ {
		reg.RecordProviderOutcome(p.ID, false, 500, "internal error")
	}
	stale := p.gate.Load()
	nowNS := time.Now().UnixNano()
	if !stale.breakerOpenAt(nowNS) {
		t.Fatal("precondition: breaker open on the session gate")
	}

	p.SetAttestationResult(&attestation.VerificationResult{Valid: true, SerialNumber: "SER-MIG-VIEW"})

	target := p.gate.Load()
	if target == stale || target.key != "serial:SER-MIG-VIEW" {
		t.Fatalf("cached gate after bind = %+v, want the identity's gate", target)
	}
	if !target.breakerOpenAt(nowNS) {
		t.Fatal("the target must carry the merged breaker state when the pointer is repointed")
	}
	if !stale.breakerOpenAt(nowNS) {
		t.Fatal("the orphaned gate's atomics must stay conservative (never republished after the reset)")
	}
	if stale.forwardTo.Load() != target || !stale.resolve().breakerOpenAt(nowNS) {
		t.Fatal("the orphan must forward to the live gate")
	}
	if !reg.ProviderBreakerOpen(p.ID) {
		t.Fatal("the breaker must read open through the session after the rebind")
	}
}

// A rebind that moves ONE of two sessions bound to the same identity must not
// orphan the shared gate: the other session still points at it, so it stays
// in the index (emptied, as the map-keyed implementation left the old key).
func TestRebindKeepsSharedIdentityGateForOtherSessions(t *testing.T) {
	reg := New(testLogger())
	p1 := makeSchedulerProvider(t, reg, "sess-shared-1", "m", 100)
	p2 := makeSchedulerProvider(t, reg, "sess-shared-2", "m", 100)
	p1.SetAttestationResult(&attestation.VerificationResult{Valid: true, PublicKey: "PK-SHARED"})
	p2.SetAttestationResult(&attestation.VerificationResult{Valid: true, PublicKey: "PK-SHARED"})
	shared := reg.lookupGateForKey("sekey:PK-SHARED")
	if shared == nil || p1.gate.Load() != shared || p2.gate.Load() != shared {
		t.Fatal("both sessions must share the identity's gate")
	}
	reg.RecordProviderOutcome(p1.ID, false, 500, "internal error")

	// p1 enriches to a serial; p2 stays on the SE key.
	p1.SetAttestationResult(&attestation.VerificationResult{Valid: true, PublicKey: "PK-SHARED", SerialNumber: "SER-ONE"})
	if rawGateForKey(reg, "sekey:PK-SHARED") != shared {
		t.Fatal("the shared gate must stay in the index while another session is bound to it")
	}
	if shared.forwardTo.Load() != nil {
		t.Fatal("a gate with a live session must not be forwarded")
	}
	if p2.gate.Load() != shared {
		t.Fatal("the other session's cached gate must be untouched")
	}
	if !gateHasBreakerWindow(reg, "serial:SER-ONE") {
		t.Fatal("the fault history must have moved to the enriched identity")
	}
	if gateHasBreakerWindow(reg, "sekey:PK-SHARED") {
		t.Fatal("the source identity must start from nothing after the migration")
	}
	reg.gatesMu.RLock()
	live := shared.live
	reg.gatesMu.RUnlock()
	if live != 1 {
		t.Fatalf("shared gate live sessions = %d, want 1", live)
	}
}

// A rebind repoints p.gate, and the reservation commit reads p.gate (the
// admit re-check) and acts on the verdict (the pending debit) inside ONE p.mu
// section — as do the scan's gate chain and the alias resolver's routability
// read. If the bind ran outside p.mu, it could land in between: a commit that
// accepted the session's clean gate would debit a session whose destination
// gate already carries a breaker (a machine re-enriching to the serial that
// tripped it last time). So the bind runs under p.mu, and p.gate never changes
// underneath a p.mu holder: a section that read a clean gate debits that same
// identity. Both entry points flap the session between a clean identity and a
// breaker-open one while a "commit" keeps checking; the invariant is exact,
// the interleaving is the race detector's. Once the flapping stops, the
// identity's breaker gates the session end to end.
func TestProviderGateNeverMovesUnderTheProviderLock(t *testing.T) {
	const model = "m"
	cases := []struct {
		name   string
		clean  func(p *Provider) // binds the session to the CLEAN identity
		dirty  func(p *Provider) // rebinds it to the quarantined one
		dstKey string
	}{
		{
			name: "attestation enrichment",
			clean: func(p *Provider) {
				p.SetAttestationResult(&attestation.VerificationResult{Valid: true, PublicKey: "PK-BINDLOCK"})
			},
			dirty: func(p *Provider) {
				p.SetAttestationResult(&attestation.VerificationResult{Valid: true, PublicKey: "PK-BINDLOCK", SerialNumber: "SER-BINDLOCK"})
			},
			dstKey: "serial:SER-BINDLOCK",
		},
		{
			name: "account linkage",
			clean: func(p *Provider) {
				p.mu.Lock()
				p.AccountID = "ACCT-CLEAN"
				p.mu.Unlock()
				p.RebindStableFaultKey()
			},
			dirty: func(p *Provider) {
				p.mu.Lock()
				p.AccountID = "ACCT-BINDLOCK"
				p.mu.Unlock()
				p.RebindStableFaultKey()
			},
			dstKey: "acct:ACCT-BINDLOCK",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			reg := New(testLogger())
			p := makeSchedulerProvider(t, reg, "sess-bindlock", model, 100)
			// A clean alternative, so the end-to-end check below is not the
			// breaker fail-open (a lone breaker-open provider still serves).
			other := makeSchedulerProvider(t, reg, "sess-bindlock-other", model, 100)
			// The quarantined destination: its breaker tripped under a previous
			// session of the same machine. The breaker travels with the session
			// on every rebind (mergeLocked keeps the later expiry), so from the
			// first dirty bind on the session is gated whichever identity it is
			// on; what the checker asserts is that it never sees the identity
			// CHANGE underneath it.
			withGateForKey(reg, tc.dstKey, func(g *gateState) { g.breakerUntil = time.Now().Add(time.Hour) })
			tc.clean(p)
			if src := p.gate.Load(); src == nil || src.key == tc.dstKey {
				t.Fatalf("precondition: the session must start on a gate other than %s, got %+v", tc.dstKey, src)
			}
			nowNS := time.Now().UnixNano()

			var moved atomic.Int64
			stop := make(chan struct{})
			var wg sync.WaitGroup
			wg.Add(2)
			// The commit: read the gate, decide, act — all under p.mu.
			go func() {
				defer wg.Done()
				for {
					select {
					case <-stop:
						return
					default:
					}
					p.mu.Lock()
					g := p.gate.Load()
					_ = g.breakerOpenAt(nowNS) // the admit re-check
					runtime.Gosched()
					runtime.Gosched()
					if p.gate.Load() != g { // the debit lands on a different identity
						moved.Add(1)
					}
					p.mu.Unlock()
				}
			}()
			// The rebinds.
			go func() {
				defer wg.Done()
				for i := 0; i < 3000; i++ {
					tc.dirty(p)
					tc.clean(p)
				}
				tc.dirty(p)
				close(stop)
			}()
			wg.Wait()
			if n := moved.Load(); n != 0 {
				t.Fatalf("p.gate changed under p.mu %d times: a commit that accepted one identity debited another", n)
			}
			g := p.gate.Load()
			if g == nil || g.key != tc.dstKey || !g.breakerOpenAt(nowNS) {
				t.Fatalf("after the last rebind p.gate = %+v, want the breaker-open %s", g, tc.dstKey)
			}
			// From here the identity's breaker gates the session end to end.
			pr := &PendingRequest{
				RequestID:             "bindlock-" + tc.name,
				Model:                 model,
				EstimatedPromptTokens: 200,
				RequestedMaxTokens:    128,
				FirstContentBudgetMS:  10_000,
				FirstContentDeadline:  time.Now().Add(10 * time.Second),
			}
			if got, _ := reg.ReserveProviderEx(model, pr); got != other {
				t.Fatalf("reservation = %v, want %s (the rebound session's identity is breaker-open)", got, other.ID)
			}
		})
	}
}
