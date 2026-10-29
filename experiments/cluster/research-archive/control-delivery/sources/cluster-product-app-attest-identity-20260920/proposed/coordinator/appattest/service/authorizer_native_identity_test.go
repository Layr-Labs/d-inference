package service

import (
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"strings"
	"testing"
	"time"
)

func TestAppAttestAuthorizerCarriesOnlyVerifiedStatusSigner(t *testing.T) {
	s, p, record, state := newAuthorizationFixture(t)
	if !s.authorizer.apply(p, record, state, time.Now()) {
		t.Fatal("fixture grant")
	}
	lease := p.GetAppAttestServingAuthorization()
	if lease.VerifiedControlPublicKey != record.status.AttestationPublicKey || lease.VerifiedBinaryHash != record.status.BinaryHash || lease.VerifiedControlPublicKey == lease.Endpoint {
		t.Fatal("proof binding lost or inferred from endpoint")
	}
	// Even the test callback cannot authorize a signer detached from the actual
	// registration after its release check; the registry rechecks under locks.
	record.status.AttestationPublicKey = "substitution"
	if s.authorizer.apply(p, record, state, time.Now()) {
		t.Fatal("changed signer granted")
	}
}

func TestAppAttestAuthorizerDoesNotCarryUnverifiedV3Key(t *testing.T) {
	for _, mode := range []string{"unknown", "mismatch", "v2"} {
		t.Run(mode, func(t *testing.T) {
			s, p, record, state := newAuthorizationFixture(t)
			switch mode {
			case "unknown":
				record.evidence.VerificationKeyKnown = false
			case "mismatch":
				record.evidence.VerificationKeyMatched = false
			case "v2":
				record.evidence.ProtocolVersion = 2
			}
			if s.authorizer.apply(p, record, state, time.Now()) {
				t.Fatal("unverified signer granted")
			}
			if p.GetAppAttestServingAuthorization().VerifiedControlPublicKey != "" {
				t.Fatal("failed verification published signer")
			}
		})
	}
}

func TestAppAttestAuthorizerCarriesTypedRuntimeWithoutLateRead(t *testing.T) {
	s, p, record, state := newAuthorizationFixture(t)
	before := s.currentReleasePolicy()
	s.currentReleasePolicy = func() ReleasePolicy {
		policy := before
		policy.ApprovedRuntime = func(_ *registry.Provider, status *protocol.AppAttestStatus) (registry.AppAttestRuntimeBinding, bool) {
			return registry.AppAttestRuntimeBinding{ControlPublicKey: status.AttestationPublicKey, BinaryHash: status.BinaryHash, MetallibHash: strings.Repeat("b", 64)}, true
		}
		return policy
	}
	if !s.authorizer.apply(p, record, state, time.Now()) {
		t.Fatal("typed fixture")
	}
	if p.GetAppAttestServingAuthorization().VerifiedMetallibHash != strings.Repeat("b", 64) {
		t.Fatal("metal approval lost")
	}
	// The callback returns its captured approval even after current registration
	// changes; grant must compare to that value rather than copying current data.
	p.Mu().Lock()
	p.AttestationResult.MetallibHash = strings.Repeat("c", 64)
	p.TemplateHashes["mlx_metallib"] = strings.Repeat("c", 64)
	p.Mu().Unlock()
	if s.authorizer.apply(p, record, state, time.Now()) {
		t.Fatal("late runtime read substituted approval")
	}
}
