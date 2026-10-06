package registry_test

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/identitygate"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func TestDisconnectedGateRefFollowsSharedIdentityEnrichment(t *testing.T) {
	for _, captureWhileLive := range []bool{false, true} {
		name := "cached-ref"
		if captureWhileLive {
			name = "live-ref-then-disconnect"
		}
		t.Run(name, func(t *testing.T) {
			gates := identitygate.New(testLogger(), nil)
			reg := production.NewWithDependencies(testLogger(), production.Dependencies{IdentityGates: gates})
			const model = "m"
			identity := &attestation.VerificationResult{Valid: true, PublicKey: "PK-CACHED-REF"}
			bind := func(id string) *production.Provider {
				p := makeSchedulerProvider(t, reg, id, model, 100)
				p.SetAttestationResult(identity)
				p.SetVersion("0.9.0")
				return p
			}
			old := bind("cached-ref-old")
			current := bind("cached-ref-current")
			sibling := bind("cached-ref-sibling")
			var ref identitygate.Reference
			var source identitygate.DisconnectSource
			if captureWhileLive {
				ref = gates.ResolveSession(old.ID, true)
				source = gates.CaptureDisconnectSource(old.ID)
			}
			reg.DisconnectWithReason(old.ID, production.DisconnectReasonReadError)
			if !captureWhileLive {
				ref = gates.ResolveSession(old.ID, true)
				source = gates.CaptureDisconnectSource(old.ID)
				if ref.IsLive() || gates.DisconnectedIdentity(old.ID) != "sekey:PK-CACHED-REF" {
					t.Fatal("cached resolution did not retain the small identity binding")
				}
			}
			disconnectedAt := gates.CaptureDisconnectSource(old.ID).OccurredAt()
			shared := gates.ViewReference(ref)
			current.SetVersion("0.9.1")
			// A real post-reset pair state also exercises the lock-free false
			// flag path after the shared source is emptied by migration.
			gates.RecordDispatchLoadFailureUntil(gates.ResolveSession(current.ID, true), model, time.Now().Add(time.Minute))
			current.SetAttestationResult(&attestation.VerificationResult{
				Valid: true, PublicKey: identity.PublicKey, SerialNumber: "SER-UPGRADE",
			})
			target := gates.ViewReference(gates.ResolveSession(current.ID, false))
			_, forwarded := shared.FollowMigration()
			if target.SameIdentity(shared) || !gates.ViewReference(gates.ResolveSession(sibling.ID, false)).SameIdentity(shared) || forwarded {
				t.Fatal("precondition: a live sibling must retain the unforwarded source")
			}
			cachedID := gates.DisconnectedIdentity(old.ID)
			cachedAt := gates.CaptureDisconnectSource(old.ID).OccurredAt()
			if cachedID != "serial:SER-UPGRADE" || !cachedAt.Equal(disconnectedAt) {
				t.Fatalf("cached identity/time = %q/%v, want %q/%v", cachedID, cachedAt, "serial:SER-UPGRADE", disconnectedAt)
			}

			applied, _, _ := gates.RecordProviderOutcomeResolved(ref, identitygate.NewRetryBudget(), false, 429, "")
			if !applied.SameIdentity(target) {
				t.Fatal("old-session recorder locked the emptied source instead of the enriched identity")
			}
			if !gates.SupersedesDisconnect(ref, source) {
				t.Fatal("stale recorder missed the new binary's migrated reset marker")
			}

			resolved, has := gates.PrepareDispatchLoadClear(ref)
			if !has || !gates.ViewReference(resolved).SameIdentity(target) || resolved.IsLive() {
				t.Fatal("stale false flag did not re-resolve through the redirected disconnect cache")
			}
			if !reg.IsSupersededDisconnectFlush(old.ID, 502, protocol.CoordinatorCauseProviderDisconnected) {
				t.Fatal("fresh old-session lookup lost the version reset after enrichment")
			}
		})
	}
}
