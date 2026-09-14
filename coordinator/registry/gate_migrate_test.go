package registry

import (
	"github.com/eigeninference/d-inference/coordinator/attestation"
	"runtime"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// Tests for the identity migration (gate_migrate.go): stale cached pointers
// follow the forward, lock-free readers never see an empty gate mid-rebind,
// and a shared identity gate stays in the index for its other sessions.

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
			reg := newClockedFaultRegistry(t)
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
			withFaultFixtureTime(reg, time.Now().Add(time.Hour-providerBreakerBaseCooldown), func() {
				for range providerBreakerConsecTrip {
					reg.RecordProviderOutcome(tc.dstKey, false, 500, "internal error")
				}
			})
			tc.clean(p)
			if src := reg.gateOf(p); !src.Present() || src.Key() == tc.dstKey {
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
					g := reg.gateOf(p)
					_ = g.BreakerOpenAt(nowNS) // the admit re-check
					runtime.Gosched()
					runtime.Gosched()
					if !reg.gateOf(p).SameGate(g) { // the debit lands on a different identity
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
			g := reg.gateOf(p)
			if !g.Present() || g.Key() != tc.dstKey || !g.BreakerOpenAt(nowNS) {
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
