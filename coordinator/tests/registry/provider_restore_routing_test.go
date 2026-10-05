package registry_test

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/warmplan"
	production "github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

func TestProviderPendingRestoreCannotRoute(t *testing.T) {
	r := newGateCharacterizationRegistry()
	// Registration against a durable store keeps restoration pending until the
	// identity lookup and history restoration have completed.
	r.SetStore(memory.NewMemory(store.Config{}))
	p := baselineGateProvider(t, r, func(p *production.Provider) {
		p.AttestationResult = &attestation.VerificationResult{Valid: true, SerialNumber: "serial", PublicKey: "se"}
		p.AccountID = "owner"
	})
	got := collectGateOutcomes(r, p, gateCharModel, time.Now())
	if got.routingGates || got.routingGatesSelf || got.routingGatesBypass || got.canRoutePublic || got.canRouteRelaxed || got.hasWarm || got.publiclyRoutable || got.modelLoadCand || got.warmReason == warmplan.WarmColdEligible {
		t.Fatalf("incomplete recovery can receive work: %+v", got)
	}
	if online, serves := r.OwnedProviderSummary("owner", gateCharModel, production.RequestTraits{}, false); online != 1 || serves != 0 {
		t.Fatalf("owner preflight advertised incomplete recovery: online=%d serves=%d", online, serves)
	}
	p.CompleteProviderStateRestore()
	if got := collectGateOutcomes(r, p, gateCharModel, time.Now()); !got.routingGates || !got.publiclyRoutable {
		t.Fatalf("completed recovery did not restore eligibility: %+v", got)
	}
	if _, serves := r.OwnedProviderSummary("owner", gateCharModel, production.RequestTraits{}, false); serves != 1 {
		t.Fatal("owner preflight did not recover after restoration")
	}
}
