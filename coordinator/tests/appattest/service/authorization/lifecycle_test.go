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
