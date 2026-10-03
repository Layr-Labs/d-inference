package trust

import (
	"github.com/eigeninference/d-inference/coordinator/store"
	"strings"
	"testing"
)

func TestAppAttestReleaseAdapterPinsApprovalToItsGeneration(t *testing.T) {
	s, p, status := newAuthorizationFixture(t)
	before := s.currentAppAttestReleasePolicy()
	policy := publishTestReleasePolicy(t, s, store.Release{BinaryHash: strings.Repeat("a", 64), Version: "0.9.4", Platform: "macos-arm64", MetallibHash: strings.Repeat("c", 64)})
	after := s.currentAppAttestReleasePolicy()
	if before.Generation >= policy.Generation || !before.Known || !before.Approves(p, status) {
		t.Fatal("old approval reloaded a different generation")
	}
	if after.Generation != policy.Generation || !after.Known || after.Approves(p, status) {
		t.Fatal("new generation retained old runtime approval")
	}
}
