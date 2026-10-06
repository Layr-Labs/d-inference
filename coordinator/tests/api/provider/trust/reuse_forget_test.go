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
	c.RecordTrust(c.PublicationGeneration(), hardwareReuseRecord("se-erased", "SERIAL", trHashA, cur))
	c.RecordTrust(c.PublicationGeneration(), hardwareReuseRecord("se-kept", "OTHER", trHashA, cur))

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

// A durable write can commit before the scrub while its caller is descheduled
// before cache publication. Forget must win that schedule, including recovery
// and authoritative revocation responses carrying the old personal fields.
func TestTrustReuseForgetFencesCapturedPublication(t *testing.T) {
	for _, mode := range []string{"record", "recover", "authoritative"} {
		t.Run(mode, func(t *testing.T) {
			c := trustreuse.New()
			rec := hardwareReuseRecord("se-erased", "SERIAL", trHashA, time.Now())
			rec.MDAUDID = "personal-udid"
			generation := c.PublicationGeneration()
			c.RecordTrust(generation, rec)
			c.Forget([]string{rec.SEPubKey})
			switch mode {
			case "record":
				if c.RecordTrust(generation, rec) {
					t.Fatal("stale publication succeeded")
				}
			case "recover":
				if c.RecoverTrust(generation, rec, rec.RevocationGeneration) {
					t.Fatal("stale recovery succeeded")
				}
			case "authoritative":
				c.InstallAuthoritativeTrustReuse(generation, rec)
			}
			if c.HasFreshRecord(rec.SEPubKey, rec.Serial) {
				t.Fatal("erased serial restored in cache")
			}
			// A new verification admitted by the durable owner gate can still publish.
			if !c.RecordTrust(c.PublicationGeneration(), rec) {
				t.Fatal("new publication refused")
			}
		})
	}
}
