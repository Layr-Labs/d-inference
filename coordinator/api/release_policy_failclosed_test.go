package api

import (
	"errors"
	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
	"strings"
	"sync"
	"testing"
)

type releaseInventoryFailureStore struct {
	*memory.MemoryStore
	mu              sync.Mutex
	failReads       bool
	emptyReads      bool
	failAfterDelete bool
	deleteCalls     int
}

func (s *releaseInventoryFailureStore) ListReleasesWithError() ([]store.Release, error) {
	s.mu.Lock()
	fail := s.failReads
	empty := s.emptyReads
	s.mu.Unlock()
	if fail {
		return nil, errors.New("simulated release inventory read failure")
	}
	if empty {
		return []store.Release{}, nil
	}
	return s.MemoryStore.ListReleasesWithError()
}

func (s *releaseInventoryFailureStore) DeleteRelease(version, platform string) error {
	if err := s.MemoryStore.DeleteRelease(version, platform); err != nil {
		return err
	}
	s.mu.Lock()
	s.deleteCalls++
	if s.failAfterDelete {
		s.failReads = true
	}
	s.mu.Unlock()
	return nil
}

func (s *releaseInventoryFailureStore) setFailReads(fail bool) {
	s.mu.Lock()
	s.failReads = fail
	s.mu.Unlock()
}

func testRelease(version, hash string) *store.Release {
	return &store.Release{
		Version: version, Platform: "macos-arm64", Backend: registry.BackendMLXSwift,
		BinaryHash: hash, BundleHash: strings.Repeat("f", 64),
		MetallibHash: trHashC,
		URL:          "https://releases.example/" + version + ".tar.gz",
	}
}

func grantReleaseEvidenceForTest(t *testing.T, provider *registry.Provider, generation uint64, version, binaryHash string) {
	t.Helper()
	provider.Mu().Lock()
	provider.Version = version
	provider.APNsDeviceToken = "apns-token"
	provider.MetallibVerified = true
	provider.AttestationResult = &attestation.VerificationResult{
		Valid: true, PublicKey: "se-release", SerialNumber: "SER-RELEASE",
	}
	provider.Mu().Unlock()
	if !provider.GrantApplicationEvidenceIfNotUntrusted(registry.ApplicationEvidence{
		SEPublicKey: "se-release", Serial: "SER-RELEASE",
		ProcessPublicKey: provider.PublicKey, APNsToken: "apns-token",
		BinaryHash: binaryHash, Version: version, Platform: "macos-arm64",
		Backend: registry.BackendMLXSwift, MetallibHash: trHashC,
		PolicyGeneration: generation,
	}) {
		t.Fatal("failed to grant release evidence test precondition")
	}
}

// Te
