package api

import (
	"github.com/eigeninference/d-inference/coordinator/registry"
	"strings"
	"testing"
	"time"
)

// waitForCond polls cond up to d, returning its final value. Used to observe a
// goroutine-driven re-arm/attestation outcome without a fixed sleep.
func waitForCond(d time.Duration, cond func() bool) bool {
	deadline := time.Now().Add(d)
	for time.Now().Before(deadline) {
		if cond() {
			return true
		}
		time.Sleep(time.Millisecond)
	}
	return cond()
}

func fastBudgets(srv *Server) {
	srv.codeAttestThrottle.backgroundPushCooldown = time.Millisecond
	srv.codeAttestThrottle.alertPushCooldown = time.Millisecond
	srv.codeAttestThrottle.budgetClearCooldown = time.Millisecond
	srv.codeAttestThrottle.retrySpacing = time.Millisecond
	srv.codeAttestThrottle.retryJitter = 0
}

func providerToken(p *registry.Provider) string {
	p.Mu().Lock()
	defer p.Mu().Unlock()
	return p.APNsDeviceToken
}

// crossVersionProvider builds a fully-fenced provider running newVersion: valid
// attestation, runtime+manifest verified, SIP-verified challenge, same SE key +
// APNs token. Transition reuse additionally requires current generation-bound
// application evidence attesting this provider's exact process key.
func crossVersionProvider(kPubB64, sePubB64, newVersion string) *registry.Provider {
	p := newCodeAttestProvider(kPubB64, sePubB64)
	p.Version = newVersion
	p.Backend = "mlx-swift"
	p.RuntimeVerified = true
	p.RuntimeManifestChecked = true
	p.MetallibVerified = true
	p.ChallengeVerifiedSIP = true
	p.AttestationResult.SerialNumber = "SERIAL"
	p.AttestationResult.BinaryHash = strings.Repeat("a", 64)
	return p
}

func seedFreshProcessAttestation(
	srv *Server, seKey, oldVersion, token, nodeKey, binaryHash string,
) {
	srv.codeAttestThrottle.recordAttestedForProcess(
		seKey, oldVersion, token, nodeKey, binaryHash)
}

// armCrossVersionApplicationEvidence publishes a release policy whose ACTIVE
// inventory holds the current release (trHashA, p.Version) and its approved
// predecessor release (trHashB, 0.6.13), then grants current generation-bound
// application evidence for the provider's exact process key.
func armCrossVersionApplicationEvidence(
	t *testing.T, srv *Server, p *registry.Provider, sePubB64 string,
) {
	t.Helper()
	armCrossVersionApplicationEvidenceWithPolicy(t, srv, p, sePubB64,
		map[string][]approvedReleasePolicy{
			trHashA: {{Version: p.Version, Platform: "macos-arm64", Backend: p.Backend}},
			trHashB: {{Version: "0.6.13", Platform: "macos-arm64", Backend: p.Backend}},
		})
}

func armCrossVersionApplicationEvidenceWithPolicy(
	t *testing.T, srv *Server, p *registry.Provider, sePubB64 string,
	byBinaryHash map[string][]approvedReleasePolicy,
) {
	t.Helper()
	const policyGeneration = 1
	srv.releaseTrustPolicy.Store(&releaseTrustPolicySnapshot{
		Generation:   policyGeneration,
		Required:     true,
		ByBinaryHash: byBinaryHash,
	})
	if !p.GrantApplicationEvidenceIfNotUntrusted(registry.ApplicationEvidence{
		SEPublicKey:      sePubB64,
		Serial:           "SERIAL",
		ProcessPublicKey: p.PublicKey,
		APNsToken:        p.APNsDeviceToken,
		BinaryHash:       strings.Repeat("a", 64),
		Version:          p.Version,
		Platform:         "macos-arm64",
		Backend:          p.Backend,
		VerifiedAt:       time.Now(),
		PolicyGeneration: policyGeneration,
	}) {
		t.Fatal("precondition: current generation-bound application evidence was rejected")
	}
}
