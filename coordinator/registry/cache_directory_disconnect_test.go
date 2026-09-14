package registry

import "testing"

func TestDisconnectWithoutCacheDirectory(t *testing.T) {
	r, p, _ := exactTestRegistry(t)
	r.cacheRouting = nil
	r.Disconnect(p.ID)
	if r.GetProvider(p.ID) != nil {
		t.Fatal("disconnect retained provider without a cache directory")
	}
}
