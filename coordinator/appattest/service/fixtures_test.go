package service

import (
	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
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

// testShadowStatus is the minimal signed status a protocol-3 provider sends
// with an attestation or assertion.
func testShadowStatus() *protocol.AppAttestStatus {
	return &protocol.AppAttestStatus{OSVersion: "27"}
}

// testAssertionHash is the protocol-3 client hash an assertion for x's
// current challenge signs over status.
func testAssertionHash(x *Session, keyID string, status *protocol.AppAttestStatus) [32]byte {
	return protocol.AppAttestShadowHashV3("assert", x.id, x.s.config.Environment, keyID, x.challenge, x.publicKey, x.accountScope(), status)
}
