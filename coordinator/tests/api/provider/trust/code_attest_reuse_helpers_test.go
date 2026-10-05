package trust_test

import (
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
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

func fastBudgets(srv *trustFixture) {
	srv.codeAttestThrottle.BackgroundPushCooldown = time.Millisecond
	srv.codeAttestThrottle.AlertPushCooldown = time.Millisecond
	srv.codeAttestThrottle.BudgetClearCooldown = time.Millisecond
	srv.codeAttestThrottle.RetrySpacing = time.Millisecond
	srv.codeAttestThrottle.RetryJitter = 0
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
	srv *trustFixture, seKey, oldVersion, token, nodeKey, binaryHash string,
) {
	srv.codeAttestThrottle.RecordAttestedForProcess(
		seKey, oldVersion, token, nodeKey, binaryHash)
}

// armCrossVersionApplicationEvidence publishes a release policy whose ACTIVE
// inventory holds the current release (trHashA, p.Version) and its approved
// predecessor release (trHashB, 0.6.13), then grants current generation-bound
// application evidence for the provider's exact process key.
func armCrossVersionApplicationEvidence(
	t *testing.T, srv *trustFixture, p *registry.Provider, sePubB64 string,
) {
	t.Helper()
	armCrossVersionApplicationEvidenceWithPolicy(t, srv, p, sePubB64,
		map[string][]store.Release{
			trHashA: {{Version: p.Version, Platform: "macos-arm64", Backend: p.Backend}},
			trHashB: {{Version: "0.6.13", Platform: "macos-arm64", Backend: p.Backend}},
		})
}

func armCrossVersionApplicationEvidenceWithPolicy(
	t *testing.T, srv *trustFixture, p *registry.Provider, sePubB64 string,
	byBinaryHash map[string][]store.Release,
) {
	t.Helper()
	var rows []store.Release
	for hash, entries := range byBinaryHash {
		for _, entry := range entries {
			entry.BinaryHash = hash
			rows = append(rows, entry)
		}
	}
	policyGeneration := publishTestReleasePolicy(t, srv, rows...).Generation
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
