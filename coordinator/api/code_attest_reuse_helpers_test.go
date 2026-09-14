package api

import (
	"context"
	"github.com/eigeninference/d-inference/coordinator/providercontrol/codeidentity"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
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

type codeIdentityFixture struct {
	now          func() time.Time
	resumeSender codeidentity.ResumeSender
}

func configureCodeIdentityFixture(srv *Server, cfg codeidentity.Config) *codeIdentityFixture {
	control := &codeIdentityFixture{now: cfg.Now}
	cfg.Now = func() time.Time { return control.now() }
	deps := srv.codeIdentityDependencies()
	deps.ResumeSender = func() codeidentity.ResumeSender { return control.resumeSender }
	srv.codeIdentity = codeidentity.New(cfg, deps)
	return control
}

func fastBudgets(srv *Server) *codeIdentityFixture {
	cfg := codeidentity.DefaultConfig()
	cfg.BackgroundPushCooldown = time.Millisecond
	cfg.AlertPushCooldown = time.Millisecond
	cfg.BudgetClearCooldown = time.Millisecond
	cfg.RetrySpacing = time.Millisecond
	cfg.RetryJitter = 0
	return configureCodeIdentityFixture(srv, cfg)
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
	t *testing.T, srv *Server, seKey, oldVersion, token, nodeKey, binaryHash string,
) {
	t.Helper()
	proof := store.CodeAttestation{SEPubKey: seKey, Version: oldVersion, APNsToken: token,
		NodePublicKey: nodeKey, BinaryHash: binaryHash, AttestedAt: time.Now()}
	seedCodeIdentityProof(t, srv, proof)
}

// Seed through the real store interface rather than reaching into the owner's
// private cache. This is fixture evidence, never a live trust grant.
func seedCodeIdentityProof(t *testing.T, srv *Server, proof store.CodeAttestation) {
	t.Helper()
	if err := srv.store.UpsertCodeAttestation(context.Background(), proof); err != nil {
		t.Fatal(err)
	}
	srv.SeedCodeAttestCache(context.Background())
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
