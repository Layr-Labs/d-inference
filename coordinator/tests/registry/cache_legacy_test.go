package registry_test

import (
	"testing"

	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func TestLegacyCacheBustKeyLengthMatchesSizingContract(t *testing.T) {
	r, provider, _ := exactTestRegistry(t)
	provider.Mu().Lock()
	provider.PrefixCacheProtocol = 0
	provider.Mu().Unlock()
	pr := &production.PendingRequest{RequestID: "v0-sizing", Model: "model"}
	if err := r.PrepareCacheAttempt(pr, provider); err != nil {
		t.Fatal(err)
	}
	if len(pr.LegacyCacheBustKey) != production.LegacyCacheBustKeyLength {
		t.Fatalf("legacy cache-bust key length = %d, want %d",
			len(pr.LegacyCacheBustKey), production.LegacyCacheBustKeyLength)
	}
}
