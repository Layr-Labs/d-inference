package registry

// Tests for the MDA SIP routing gate (issue #302 Gap 3): once enforcement is
// past its deadline, the single routing chokepoint must require a fresh
// SEP-signed SIP-on/Full-Security verdict (MDASIPVerified + mint age within
// attestation.MDAMaxCertAge) — the self-reported ChallengeVerifiedSIP alone no
// longer routes. Grace mode (zero/future deadline) must keep the fleet routing.

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestMDAGateGraceAndEnforcement(t *testing.T) {
	reg := New(testLogger())
	const build = aliasQAT

	p := registerProviderWithModel(reg, "p1", build)
	makeProviderRoutable(p) // hardware trust + live challenge + self-reported SIP

	routable := func() bool {
		ids := reg.RoutableProviderIDsForBuild(build)
		return len(ids) == 1 && ids[0] == "p1"
	}

	// Grace (no deadline): routable without any MDA verdict — rollout safety.
	if !routable() {
		t.Fatal("grace mode (no deadline) must keep the provider routable")
	}

	// Future deadline: still grace.
	reg.SetMDAEnforceDeadline(time.Now().Add(time.Hour))
	if !routable() {
		t.Fatal("a future deadline is still grace — provider must stay routable")
	}

	// Past deadline: enforcement. Self-reported SIP alone must STOP routing.
	reg.SetMDAEnforceDeadline(time.Now().Add(-time.Minute))
	if routable() {
		t.Fatal("enforced: a provider without a fresh MDA SIP verdict must not route (self-reported SIP is not enough)")
	}

	// A fresh verified verdict routes.
	p.Mu().Lock()
	p.MDASIPVerified = true
	p.MDAMintedAt = time.Now().Add(-time.Hour)
	p.Mu().Unlock()
	if !routable() {
		t.Fatal("enforced: a fresh MDA SIP verdict must route")
	}

	// A verdict whose cert mint time exceeded MDAMaxCertAge expires at routing
	// time — even though MDASIPVerified is still set (re-attestation stalled).
	p.Mu().Lock()
	p.MDAMintedAt = time.Now().Add(-attestation.MDAMaxCertAge - time.Hour)
	p.Mu().Unlock()
	if routable() {
		t.Fatal("enforced: a verdict older than MDAMaxCertAge must stop routing")
	}

	// Recovery: a new fresh verdict routes again.
	p.Mu().Lock()
	p.MDAMintedAt = time.Now().Add(-time.Hour)
	p.Mu().Unlock()
	if !routable() {
		t.Fatal("a renewed fresh verdict must route again")
	}
}

// RestoreProviderState must NOT resurrect the MDA verdict across reconnects: a
// SIP downgrade requires a reboot, which drops the connection — restoring the
// stored flag would bridge exactly that window. (The stored record keeps the
// field for back-compat; it is simply no longer applied.)
func TestRestoreDoesNotResurrectMDAVerified(t *testing.T) {
	reg := New(testLogger())
	p := registerProviderWithModel(reg, "p-restore", aliasQAT)

	reg.RestoreProviderState(p, &store.ProviderRecord{
		ID:          "p-restore",
		TrustLevel:  string(TrustHardware),
		Attested:    true,
		MDAVerified: true,
	})

	p.Mu().Lock()
	defer p.Mu().Unlock()
	if p.MDAVerified {
		t.Error("restore must not resurrect MDAVerified — the verdict has no cert chain behind it and must be re-earned per connection")
	}
	if p.MDASIPVerified {
		t.Error("restore must never set the MDA SIP gate verdict")
	}
	if p.TrustLevel != TrustSelfSigned {
		t.Errorf("trust restore clamp: got %v, want self_signed", p.TrustLevel)
	}
}
