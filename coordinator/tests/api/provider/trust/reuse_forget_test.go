package trust_test

import (
	"testing"
	"time"

	trustreuse "github.com/eigeninference/d-inference/coordinator/internal/provider/reuse"
)

// Account erasure drops the cached trust-reuse records of erased SE keys, so
// their next connection takes the full verification path; other keys stay.
func TestTrustReuseCacheForget(t *testing.T) {
	cur := time.Unix(1_700_000_000, 0)
	c := trustreuse.New()
	c.Now = func() time.Time { return cur }
	c.RecordTrust(hardwareReuseRecord("se-erased", "SERIAL", trHashA, cur))
	c.RecordTrust(hardwareReuseRecord("se-kept", "OTHER", trHashA, cur))

	c.Forget([]string{"se-erased"})

	if c.HasFreshRecord("se-erased", "SERIAL") {
		t.Fatal("erased record kept")
	}
	if _, ok := cachedTrust(c, "se-erased", "SERIAL", trHashA); ok {
		t.Fatal("erased key still reuses trust")
	}
	if !c.HasFreshRecord("se-kept", "OTHER") {
		t.Fatal("Forget removed another key")
	}
	var nilCache *trustreuse.Cache
	nilCache.Forget([]string{"x"})
}
