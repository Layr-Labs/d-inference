package service

import (
	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// The exchange only needs a provider's existing bound identity; HTTP upgrade,
// authentication, and the real writer remain covered by API integration tests.
func newSessionProvider(endpoint, signingKey string) *registry.Provider {
	return &registry.Provider{
		ID: "p1", PublicKey: endpoint, APNsDeviceToken: "devtok", APNsEnvironment: "production",
		AttestationResult: &attestation.VerificationResult{Valid: true, PublicKey: signingKey},
	}
}
