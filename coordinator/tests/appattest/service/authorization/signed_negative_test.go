package authorization_test

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/appattest"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/authorization"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestAppAttestSignedNegativeCannotFallbackToLegacy(t *testing.T) {
	f, p, record, state := newAuthorizationFixture(t, true)
	if !f.controller.Apply(p, record, state, time.Now()) {
		t.Fatal("grant")
	}
	p.SetAttested(true, registry.TrustHardware)
	p.CodeAttested = true
	p.ChallengeVerifiedSIP = true
	p.SetLastChallengeVerified(time.Now())
	if !f.registry.ProviderLegacyServingAuthorized(p) {
		t.Fatal("legacy fixture")
	}
	identity := authorization.NewIdentity(authorization.IdentityDependencies{Controller: f.controller, Registry: f.registry}, p, "")
	identity.Update(authorization.NewVerifiedProof(f.evidence, &f.status, "", nil, 0), appattest.AuthorizationVerdict{Outcome: "ineligible", Reasons: []string{"apple_code_measurement_mismatch"}})
	if p.GetStatus() != registry.StatusUntrusted || f.registry.ProviderLegacyServingAuthorized(p) {
		t.Fatal("signed negative bypassed by legacy")
	}
}
