package api

// Regression test for H2 (APNs code-attestation reuse staleness). The reuse
// window lets a NEW connection inherit a recent attestation without a fresh
// push/decrypt/sign; `version` is self-reported so it does not prove the binary
// is unchanged — the only real guard is keeping the staleness window tight.
// Pinning reuseWindow <= pushCooldown bounds that staleness AND guarantees a
// reconnect that can no longer reuse can always push fresh (no deroute gap).

import (
	"testing"
	"time"
)

func TestCodeAttestReuseWindow(t *testing.T) {
	th := newCodeAttestThrottle()
	base := time.Unix(1_700_000_000, 0)
	cur := base
	th.now = func() time.Time { return cur }

	th.recordAttested("seKeyA", "v1")

	// Within the window, same version → reuse honored.
	cur = base.Add(th.reuseWindow - time.Second)
	if !th.reuseAttestation("seKeyA", "v1") {
		t.Error("reuse should be honored within the window")
	}
	// Different (self-reported) version → no reuse.
	if th.reuseAttestation("seKeyA", "v2") {
		t.Error("reuse must require a matching version")
	}
	// Different device → no reuse.
	if th.reuseAttestation("seKeyB", "v1") {
		t.Error("reuse must be keyed to the device's SE key")
	}
	// Past the window → no reuse (forces a fresh push+decrypt+sign).
	cur = base.Add(th.reuseWindow + time.Second)
	if th.reuseAttestation("seKeyA", "v1") {
		t.Error("reuse must expire after the window")
	}

	// The tightening invariant: reuse staleness never exceeds one push cooldown,
	// so a reconnect that can no longer reuse can always push a fresh challenge.
	if th.reuseWindow > th.pushCooldown {
		t.Errorf("reuseWindow (%v) must be <= pushCooldown (%v) to bound staleness without a deroute gap",
			th.reuseWindow, th.pushCooldown)
	}
}
