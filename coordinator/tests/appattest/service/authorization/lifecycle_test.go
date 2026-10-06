package authorization_test

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/appattest/authorization"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestAuthorizationUsesOneImmutableReleasePolicySnapshot(t *testing.T) {
	f, p, record, state := newAuthorizationFixture(t, true)
	reads := 0
	f.policy = func() *authorization.ReleasePolicy {
		reads++
		generation := uint64(7)
		return &authorization.ReleasePolicy{Generation: generation, Known: true, Approves: func(*registry.Provider, *protocol.AppAttestStatus) bool {
			return reads == 1
		}}
	}
	if !f.controller.Apply(p, record, state, time.Now()) || reads != 1 {
		t.Fatal("approval and generation did not use the same snapshot")
	}
	if p.GetAppAttestServingAuthorization().PolicyGeneration != 7 {
		t.Fatal("grant used a different policy generation")
	}
	// A missing catalog cannot be converted into approval by an adapter's
	// nonnil callback. This preserves the pre-extraction empty-catalog guard.
	f.policy = func() *authorization.ReleasePolicy {
		return &authorization.ReleasePolicy{Generation: 7, Known: false, Approves: func(*registry.Provider, *protocol.AppAttestStatus) bool { return true }}
	}
	if f.controller.Apply(p, record, state, time.Now()) {
		t.Fatal("unknown catalog authorized a provider")
	}
}

func TestAuthorizationOSVersionComesFromVerifiedProofStatus(t *testing.T) {
	for _, version := range []string{"26.5", "27.0", "28.1.2", "", "malformed"} {
		t.Run(version, func(t *testing.T) {
			f, p, _, state := newAuthorizationFixture(t, true)
			p.AttestationResult.OSVersion = "27.0"
			f.status.OSVersion = version
			record := authorization.NewRecord(f.evidence, f.status, "proof", nil, 0)
			// Later inventory/status changes cannot replace the verified proof claim.
			f.status.OSVersion = "29.0"
			if !f.controller.Apply(p, record, state, time.Now()) {
				t.Fatal("OS reward policy must not change serving authorization")
			}
			if got := p.GetAppAttestServingAuthorization().OSVersion; got != version {
				t.Fatalf("lease OS = %q, want verified status %q", got, version)
			}
			snapshot, ok := f.registry.GetProviderRewardSnapshot(p.ID)
			if !ok || snapshot.AppAttestOSVersion != version {
				t.Fatalf("snapshot lost verified OS: %+v", snapshot)
			}
		})
	}
}
