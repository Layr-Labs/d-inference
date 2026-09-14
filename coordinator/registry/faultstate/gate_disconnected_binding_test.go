package faultstate

import (
	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"testing"
	"time"
)

func TestDisconnectedGateRefFollowsSharedIdentityEnrichment(t *testing.T) {
	for _, captureWhileLive := range []bool{false, true} {
		name := "cached-ref"
		if captureWhileLive {
			name = "live-ref-then-disconnect"
		}
		t.Run(name, func(t *testing.T) {
			reg := newTestManager(testLogger())
			const model = "m"
			identity := &attestation.VerificationResult{Valid: true, PublicKey: "PK-CACHED-REF"}
			bind := func(id string) *Session[string] {
				p := attachTestSession(reg, id)
				bindTestIdentity(reg, p, identity)
				noteTestVersion(reg, p, "0.9.0")
				return p
			}
			old := bind("cached-ref-old")
			current := bind("cached-ref-current")
			sibling := bind("cached-ref-sibling")
			var ref gateRef[string]
			var source disconnectSource[string]
			if captureWhileLive {
				ref = reg.gateForSession(old.id)
				source = reg.captureDisconnectSource(old.id)
			}
			detachTestSession(reg, old.id)
			if !captureWhileLive {
				ref = reg.gateForSession(old.id)
				source = reg.captureDisconnectSource(old.id)
				if ref.disconnectedBinding == nil {
					t.Fatal("cached resolution did not retain the small identity binding")
				}
			}
			reg.gatesMu.RLock()
			disconnectedAt := reg.disconnectedStableIDs[old.id].at
			reg.gatesMu.RUnlock()
			shared := ref.g
			noteTestVersion(reg, current, "0.9.1")
			// A real post-reset pair state also exercises the lock-free false
			// flag path after the shared source is emptied by migration.
			withGateForSession(reg, current.id, func(g *gateState) {
				g.dispatchLoadCooldowns[model] = time.Now().Add(time.Minute)
			})
			bindTestIdentity(reg, current, &attestation.VerificationResult{
				Valid: true, PublicKey: identity.PublicKey, SerialNumber: versionResetSerial,
			})
			target := current.gate.Load()
			if target == shared || sibling.gate.Load() != shared || shared.forwardTo.Load() != nil {
				t.Fatal("precondition: a live sibling must retain the unforwarded source")
			}
			reg.gatesMu.RLock()
			cached := reg.disconnectedStableIDs[old.id]
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
			if !reg.IsSupersededDisconnectFlush(old.id, disconnectFlushStatusCode, protocol.CoordinatorCauseProviderDisconnected) {
				t.Fatal("fresh old-session lookup lost the version reset after enrichment")
			}
		})
	}
}
