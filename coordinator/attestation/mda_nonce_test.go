package attestation

// Tests for the MDA epoch-nonce scheme (issue #302 Gap 1). The properties that
// matter: nonces are deterministic per (seed, epoch, SE key) so they survive
// coordinator restarts; they differ across epochs, keys, and seeds; the
// coordinator accepts exactly the last MDANonceAcceptedEpochs epochs; and the
// pre-#302 constant sha256(SE key) classifies as LEGACY (key-bound, never
// fresh) — the value an attacker replays from a captured SIP-on cert.

import (
	"bytes"
	"testing"
	"time"
)

func TestMDAEpochNonceDeterministicAndSeparated(t *testing.T) {
	seed := []byte("test-seed-0123456789abcdef0123456789abcdef")
	now := time.Unix(1_770_000_000, 0)
	epoch := MDANonceEpoch(now)
	const keyA = "se-key-A"
	const keyB = "se-key-B"

	a1 := MDAEpochNonce(seed, epoch, keyA)
	a2 := MDAEpochNonce(seed, epoch, keyA)
	if !bytes.Equal(a1, a2) {
		t.Error("nonce must be deterministic for (seed, epoch, key)")
	}
	if len(a1) != 32 {
		t.Errorf("nonce length = %d, want 32 (Apple caps the DeviceAttestationNonce at 32 bytes)", len(a1))
	}
	if bytes.Equal(a1, MDAEpochNonce(seed, epoch+1, keyA)) {
		t.Error("nonce must rotate across epochs")
	}
	if bytes.Equal(a1, MDAEpochNonce(seed, epoch, keyB)) {
		t.Error("nonce must differ across SE keys")
	}
	if bytes.Equal(a1, MDAEpochNonce([]byte("other-seed"), epoch, keyA)) {
		t.Error("nonce must differ across seeds — the seed is what makes future epochs unpredictable")
	}
}

func TestMDANonceEpochLength(t *testing.T) {
	base := time.Unix(1_770_000_000, 0)
	if MDANonceEpoch(base) != MDANonceEpoch(base.Add(time.Hour)) {
		t.Error("same epoch within an hour")
	}
	if MDANonceEpoch(base)+1 != MDANonceEpoch(base.Add(MDANonceEpochLength)) {
		t.Error("epoch must advance by exactly 1 per MDANonceEpochLength")
	}
}

func TestClassifyMDAFreshness(t *testing.T) {
	seed := []byte("test-seed-0123456789abcdef0123456789abcdef")
	now := time.Unix(1_770_000_000, 0)
	epoch := MDANonceEpoch(now)
	const seKey = "se-public-key-base64"

	cases := []struct {
		name string
		code []byte
		want MDAFreshness
	}{
		{"current epoch", MDAEpochNonce(seed, epoch, seKey), MDAFreshnessFresh},
		{"previous epoch (cached cert at boundary)", MDAEpochNonce(seed, epoch-1, seKey), MDAFreshnessFresh},
		{"two epochs back (rate-limit race)", MDAEpochNonce(seed, epoch-2, seKey), MDAFreshnessFresh},
		{"three epochs back is STALE — the replay bound", MDAEpochNonce(seed, epoch-3, seKey), MDAFreshnessNone},
		{"future epoch is unknown (we never sent it)", MDAEpochNonce(seed, epoch+1, seKey), MDAFreshnessNone},
		{"legacy constant sha256(SE key) — pre-#302 replayable value", LegacyMDANonce(seKey), MDAFreshnessLegacy},
		{"another key's current nonce", MDAEpochNonce(seed, epoch, "other-key"), MDAFreshnessNone},
		{"another seed's current nonce", MDAEpochNonce([]byte("other"), epoch, seKey), MDAFreshnessNone},
		{"garbage", []byte("garbage-nonce-bytes"), MDAFreshnessNone},
		{"empty", nil, MDAFreshnessNone},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := ClassifyMDAFreshness(tc.code, seed, now, seKey); got != tc.want {
				t.Errorf("ClassifyMDAFreshness = %v, want %v", got, tc.want)
			}
		})
	}

	// Empty SE key never classifies (nothing to bind).
	if got := ClassifyMDAFreshness(MDAEpochNonce(seed, epoch, ""), seed, now, ""); got != MDAFreshnessNone {
		t.Errorf("empty SE key must classify None, got %v", got)
	}
}

// The age bound and the nonce-acceptance window must stay consistent: a cert
// whose nonce is still accepted should not be older than MDAMaxCertAge, and
// vice versa. This pins the relationship so one constant can't drift.
func TestMDAMaxCertAgeMatchesAcceptedEpochs(t *testing.T) {
	if MDAMaxCertAge != MDANonceAcceptedEpochs*MDANonceEpochLength {
		t.Errorf("MDAMaxCertAge (%v) must equal MDANonceAcceptedEpochs (%d) × MDANonceEpochLength (%v)",
			MDAMaxCertAge, MDANonceAcceptedEpochs, MDANonceEpochLength)
	}
}
