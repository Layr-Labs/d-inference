package registry

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
)

func TestProviderPendingRestoreCannotRoute(t *testing.T) {
	r := New(testLogger())
	p := baselineGateProvider(t, r, func(p *Provider) {
		p.AttestationResult = &attestation.VerificationResult{Valid: true, SerialNumber: "serial", PublicKey: "se"}
		p.stateRestorePending = true
		p.AccountID = "owner"
	})
	got := collectGateOutcomes(r, p, gateCharModel, time.Now())
	if got.routingGates || got.routingGatesSelf || got.routingGatesBypass || got.canRoutePublic || got.canRouteRelaxed || got.hasWarm || got.publiclyRoutable || got.modelLoadCand || got.warmReason == warmColdEligible {
		t.Fatalf("incomplete recovery can receive work: %+v", got)
	}
	if online, serves := r.OwnedProviderSummary("owner", gateCharModel, RequestTraits{}, false); online != 1 || serves != 0 {
		t.Fatalf("owner preflight advertised incomplete recovery: online=%d serves=%d", online, serves)
	}
	p.CompleteProviderStateRestore()
	if got := collectGateOutcomes(r, p, gateCharModel, time.Now()); !got.routingGates || !got.publiclyRoutable {
		t.Fatalf("completed recovery did not restore eligibility: %+v", got)
	}
	if _, serves := r.OwnedProviderSummary("owner", gateCharModel, RequestTraits{}, false); serves != 1 {
		t.Fatal("owner preflight did not recover after restoration")
	}
}
