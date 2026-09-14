package registry

import (
	"testing"
	"time"
)

func TestTrustLevels(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()

	p := reg.Register("p1", nil, msg)
	if p.TrustLevel != TrustNone {
		t.Errorf("default trust level = %q, want %q", p.TrustLevel, TrustNone)
	}

	// Set self-signed trust
	p.TrustLevel = TrustSelfSigned
	if p.TrustLevel != TrustSelfSigned {
		t.Errorf("trust level = %q, want %q", p.TrustLevel, TrustSelfSigned)
	}

	// Set hardware trust
	p.TrustLevel = TrustHardware
	p.LastChallengeVerified = time.Now()
	p.ChallengeVerifiedSIP = true
	if p.TrustLevel != TrustHardware {
		t.Errorf("trust level = %q, want %q", p.TrustLevel, TrustHardware)
	}
}

func TestFindProviderSkipsSelfSigned(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()

	p1 := reg.Register("p1", nil, msg)
	p1.TrustLevel = TrustSelfSigned

	p := findRoutableProvider(reg, "mlx-community/Qwen3.5-9B-Instruct-4bit")
	if p != nil {
		t.Error("FindProvider should skip self_signed providers")
	}
}

func TestFindProviderSkipsUntrusted(t *testing.T) {
	reg := New(testLogger())
	msg := testRegisterMessage()
	reg.Register("p1", nil, msg)

	// Mark untrusted
	reg.MarkUntrusted("p1")

	// Should not find the provider
	p := findRoutableProvider(reg, "mlx-community/Qwen3.5-9B-Instruct-4bit")
	if p != nil {
		t.Error("FindProvider should skip untrusted providers")
	}
}
