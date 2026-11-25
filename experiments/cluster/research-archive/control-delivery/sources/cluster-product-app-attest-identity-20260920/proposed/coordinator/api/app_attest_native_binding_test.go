package api

import (
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

func TestAppAttestRuntimeBindingSharesExactReleaseSnapshot(t *testing.T) {
	s, p, status := newAuthorizationFixture(t)
	policy := s.currentAppAttestReleasePolicy()
	if policy.ApprovedRuntime == nil {
		t.Fatal("missing typed callback")
	}
	binding, ok := policy.ApprovedRuntime(p, status)
	if !ok || binding != (registry.AppAttestRuntimeBinding{ControlPublicKey: status.AttestationPublicKey, BinaryHash: status.BinaryHash, MetallibHash: strings.Repeat("b", 64)}) {
		t.Fatal("lost approved runtime")
	}
	s.publishReleaseTrustPolicy(&releaseTrustPolicySnapshot{Generation: 8, ByBinaryHash: map[string][]approvedReleasePolicy{strings.Repeat("a", 64): {{Version: "0.9.4", Platform: "macos-arm64", MetallibHash: strings.Repeat("c", 64)}}}})
	if _, ok := policy.ApprovedRuntime(p, status); !ok {
		t.Fatal("callback reloaded a newer snapshot")
	}
	if _, ok := s.currentAppAttestReleasePolicy().ApprovedRuntime(p, status); ok {
		t.Fatal("new catalog accepted old metal")
	}
}

func TestAppAttestRuntimeBindingRejectsPostApprovalMetalReplacement(t *testing.T) {
	s, p, status := newAuthorizationFixture(t)
	binding, ok := s.currentAppAttestReleasePolicy().ApprovedRuntime(p, status)
	if !ok {
		t.Fatal("initial binding")
	}
	lease := p.GetAppAttestServingAuthorization()
	lease.VerifiedControlPublicKey = binding.ControlPublicKey
	lease.VerifiedBinaryHash = binding.BinaryHash
	lease.VerifiedMetallibHash = binding.MetallibHash
	p.Mu().Lock()
	p.AttestationResult.MetallibHash = strings.Repeat("c", 64)
	p.TemplateHashes["mlx_metallib"] = strings.Repeat("c", 64)
	p.Mu().Unlock()
	if s.registry.GrantAppAttestServingAuthorization(p, lease) {
		t.Fatal("matched but unapproved replacement granted")
	}
}
