package registry

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
)

func TestDisconnectedGateRefFollowsSharedIdentityEnrichment(t *testing.T) {
	for _, captureWhileLive := range []bool{false, true} {
		name := "cached-ref"
		if captureWhileLive {
			name = "live-ref-then-disconnect"
		}
		t.Run(name, func(t *testing.T) {
			reg := New(testLogger())
			const model = "m"
			identity := &attestation.VerificationResult{Valid: true, PublicKey: "PK-CACHED-REF"}
			bind := func(id string) *Provider {
				p := makeSchedulerProvider(t, reg, id, model, 100)
				p.SetAttestationResult(identity)
				p.SetVersion("0.9.0")
				return p
			}
			old := bind("cached-ref-old")
			current := bind("cached-ref-current")
			sibling := bind("cached-ref-sibling")
			var ref gateRef
			var source disconnectSource
			if captureWhileLive {
				ref = reg.gateForSession(old.ID)
				source = reg.captureDisconnectSource(old.ID)
			}
			reg.DisconnectWithReason(old.ID, DisconnectReasonReadError)
			if !captureWhileLive {
				ref = reg.gateForSession(old.ID)
				source = reg.captureDisconnectSource(old.ID)
				if ref.disconnectedBinding == nil {
					t.Fatal("cached resolution did not retain the small identity binding")
				}
			}
			reg.gatesMu.RLock()
			disconnectedAt := reg.disconnectedStableIDs[old.ID].at
			reg.gatesMu.RUnlock()
			shared := ref.g
			current.SetVersion("0.9.1")
			// A real post-reset pair state also exercises the lock-free false
			// flag path after the shared source is emptied by migration.
			withGateForSession(reg, current.ID, func(g *gateState) {
				g.dispatchLoadCooldowns[model] = time.Now().Add(time.Minute)
			})
			current.SetAttestationResult(&attestation.VerificationResult{
				Valid: true, PublicKey: identity.PublicKey, SerialNumber: versionResetSerial,
			})
			target := current.gate.Load()
			if target == shared || sibling.gate.Load() != shared || shared.forwardTo.Load() != nil {
				t.Fatal("precondition: a live sibling must retain the unforwarded source")
			}
			reg.gatesMu.RLock()
			cached := reg.disconnectedStableIDs[old.ID]
			reg.gatesMu.RUnlock()
			if cached.id != versionResetStable || !cached.at.Equal(disconnectedAt) {
				t.Fatalf("cached identity/time = %q/%v, want %q/%v", cached.id, cached.at, versionResetStable, disconnectedAt)
			}

			hold := reg.lockGate(ref, "breaker")
			if hold.g != target {
				hold.unlock()
				t.Fatal("old-session recorder locked the emptied source instead of the enriched identity")
			}
			if !source.supersededBy(hold.g) {
				hold.unlock()
				t.Fatal("stale recorder missed the new binary's migrated reset marker")
			}
			hold.unlock()

			resolved, has := reg.refHasPairState(ref, gateFlagDispatchLoad)
			if !has || resolved.g != target || resolved.p != nil {
				t.Fatal("stale false flag did not re-resolve through the redirected disconnect cache")
			}
			if !reg.IsSupersededDisconnectFlush(old.ID, disconnectFlushStatusCode) {
				t.Fatal("fresh old-session lookup lost the version reset after enrichment")
			}
		})
	}
}
