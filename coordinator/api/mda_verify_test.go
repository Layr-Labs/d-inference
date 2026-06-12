package api

// Tests for the MDA routing verdict (issue #302). evaluateMDA is the pure
// decision core of verifyAppleDeviceAttestation — the full matrix runs without
// an MDM round-trip. The properties pinned here:
//   - only a FRESH (epoch-nonce), SE-key-bound, SIP-on, Full-Security,
//     serial-matching Apple verdict routes;
//   - Apple-signed violations (chain/serial/SIP/boot) are DEFINITIVE;
//   - cached/legacy/stale responses are transient — no verdict, no untrust.

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestEvaluateMDA(t *testing.T) {
	seed := []byte("test-seed-0123456789abcdef0123456789abcdef")
	now := time.Unix(1_770_000_000, 0)
	const serial = "DRXYPT2MKX"
	const seKey = "se-public-key-b64"
	freshNonce := attestation.MDAEpochNonce(seed, attestation.MDANonceEpoch(now), seKey)
	prevNonce := attestation.MDAEpochNonce(seed, attestation.MDANonceEpoch(now)-1, seKey)
	staleNonce := attestation.MDAEpochNonce(seed, attestation.MDANonceEpoch(now)-attestation.MDANonceAcceptedEpochs, seKey)

	good := func() *attestation.MDAResult {
		return &attestation.MDAResult{
			Valid:             true,
			DeviceSerial:      serial,
			SIPEnabled:        true,
			SecureBootEnabled: true,
			BootState:         "Full Security",
			FreshnessCode:     freshNonce,
			LeafNotBefore:     now.Add(-24 * time.Hour),
		}
	}

	cases := []struct {
		name       string
		mutate     func(*attestation.MDAResult)
		verified   bool
		definitive bool
		reason     string
	}{
		{"all good — verdict granted", func(m *attestation.MDAResult) {}, true, false, "ok"},
		{"previous-epoch nonce (Apple cached cert) still fresh", func(m *attestation.MDAResult) {
			m.FreshnessCode = prevNonce
		}, true, false, "ok"},
		{"chain invalid is definitive", func(m *attestation.MDAResult) {
			m.Valid = false
		}, false, true, "chain_invalid"},
		{"serial mismatch is definitive (impersonation)", func(m *attestation.MDAResult) {
			m.DeviceSerial = "OTHER-DEVICE"
		}, false, true, "serial_mismatch"},
		{"empty MDA serial does not mismatch (pre-existing semantics)", func(m *attestation.MDAResult) {
			m.DeviceSerial = ""
		}, true, false, "ok"},
		{"SIP disabled is definitive — even on a cached cert", func(m *attestation.MDAResult) {
			m.SIPEnabled = false
			m.FreshnessCode = staleNonce
		}, false, true, "sip_disabled"},
		{"non-Full-Security boot is definitive", func(m *attestation.MDAResult) {
			m.SecureBootEnabled = false
			m.BootState = "Permissive Security"
		}, false, true, "not_full_security"},
		{"legacy constant nonce — migration state, transient", func(m *attestation.MDAResult) {
			m.FreshnessCode = attestation.LegacyMDANonce(seKey)
		}, false, false, "legacy_nonce"},
		{"out-of-window nonce — the replay bound, transient", func(m *attestation.MDAResult) {
			m.FreshnessCode = staleNonce
		}, false, false, "nonce_unrecognized"},
		{"another device's fresh nonce does not bind", func(m *attestation.MDAResult) {
			m.FreshnessCode = attestation.MDAEpochNonce(seed, attestation.MDANonceEpoch(now), "other-se-key")
		}, false, false, "nonce_unrecognized"},
		{"missing freshness code — transient", func(m *attestation.MDAResult) {
			m.FreshnessCode = nil
		}, false, false, "nonce_unrecognized"},
		{"cert older than MDAMaxCertAge — age backstop", func(m *attestation.MDAResult) {
			m.LeafNotBefore = now.Add(-attestation.MDAMaxCertAge - time.Hour)
		}, false, false, "cert_too_old"},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			m := good()
			tc.mutate(m)
			eval := evaluateMDA(m, serial, seKey, seed, now)
			if eval.SIPVerified != tc.verified {
				t.Errorf("SIPVerified = %v, want %v", eval.SIPVerified, tc.verified)
			}
			if eval.Definitive != tc.definitive {
				t.Errorf("Definitive = %v, want %v", eval.Definitive, tc.definitive)
			}
			if eval.Reason != tc.reason {
				t.Errorf("Reason = %q, want %q", eval.Reason, tc.reason)
			}
		})
	}
}

// The replay scenario from issue #302 Gap 1, end to end at the decision layer:
// an attacker captures a SIP-on cert while genuinely SIP-on, reboots SIP-off,
// and replays it. Under the legacy constant nonce that cert verified forever;
// under epoch nonces it stops binding once its epoch ages out, and the routing
// verdict is denied (transient — the device can re-earn by re-attesting, which
// would then carry SIP-off and untrust it).
func TestEvaluateMDA_ReplayedCertAgesOut(t *testing.T) {
	seed := []byte("test-seed-0123456789abcdef0123456789abcdef")
	const serial, seKey = "SERIAL", "se-key"
	captureTime := time.Unix(1_770_000_000, 0)

	captured := &attestation.MDAResult{
		Valid:             true,
		DeviceSerial:      serial,
		SIPEnabled:        true,
		SecureBootEnabled: true,
		BootState:         "Full Security",
		FreshnessCode:     attestation.MDAEpochNonce(seed, attestation.MDANonceEpoch(captureTime), seKey),
		LeafNotBefore:     captureTime,
	}

	// Immediately after capture: verdict granted (the cert IS genuine + fresh).
	if eval := evaluateMDA(captured, serial, seKey, seed, captureTime.Add(time.Hour)); !eval.SIPVerified {
		t.Fatalf("freshly captured cert should verify, got %+v", eval)
	}

	// Replayed after the accepted-epoch window: denied.
	replayAt := captureTime.Add(attestation.MDANonceAcceptedEpochs*attestation.MDANonceEpochLength + time.Hour)
	eval := evaluateMDA(captured, serial, seKey, seed, replayAt)
	if eval.SIPVerified {
		t.Fatal("replayed cert past the epoch window must NOT verify — this was the unbounded-replay hole")
	}
	if eval.Definitive {
		t.Fatal("an aged-out cert is transient (the honest device re-mints), not a definitive violation")
	}
}

// HandleLateMDA must only attribute a cert that verifies to Apple's root: an
// unparseable or non-Apple chain is ignored (never sets a verdict on any
// provider). The full verdict matrix for an attributed cert is covered by
// TestEvaluateMDA; here we pin the safe rejection path and that the late
// callback runs without panicking against a populated registry.
func TestHandleLateMDA_RejectsUnattributableCert(t *testing.T) {
	logger := quietLogger()
	reg := registry.New(logger)
	srv := NewServer(reg, store.NewMemory(store.Config{}), ServerConfig{}, logger)
	srv.SetMDANonceSeed([]byte("test-seed-0123456789abcdef0123456789abcdef"))

	// A provider that would match by serial IF a cert verified — to prove the
	// chain check (not just "no provider") is what rejects.
	p := reg.Register("p-late", nil, &protocol.RegisterMessage{PublicKey: "k"})
	p.Mu().Lock()
	p.AttestationResult = &attestation.VerificationResult{SerialNumber: "SERIAL-1", PublicKey: "k"}
	p.MDASIPVerified = false
	p.Mu().Unlock()

	// Garbage and empty chains: parse/verify fails → no-op, no panic.
	srv.HandleLateMDA("udid-x", [][]byte{[]byte("not-a-cert")})
	srv.HandleLateMDA("udid-x", nil)

	p.Mu().Lock()
	defer p.Mu().Unlock()
	if p.MDASIPVerified {
		t.Error("an unverifiable late cert must never grant the MDA routing verdict")
	}
	if p.MDAVerified {
		t.Error("an unverifiable late cert must not set MDAVerified")
	}
}

// Regression for the lock-ordering deadlock (audit of #302): the late-MDA path
// applies the verdict via registry write-lock methods (MDAEnforced /
// MarkUntrusted), which must NOT be called inside ForEachProvider's read lock.
// attributeAndApplyMDA collects under the RLock then applies after. Driven with
// a hand-built verified result (a real Apple chain can't be forged in-tree): a
// late SIP-off cert under enforcement must untrust the matching provider AND
// the call must complete promptly (a deadlock would hang the whole coordinator).
func TestAttributeAndApplyMDA_LateSIPOffUntrustsWithoutDeadlock(t *testing.T) {
	logger := quietLogger()
	reg := registry.New(logger)
	srv := NewServer(reg, store.NewMemory(store.Config{}), ServerConfig{}, logger)
	srv.SetMDANonceSeed([]byte("test-seed-0123456789abcdef0123456789abcdef"))
	reg.SetMDAEnforceDeadline(time.Now().Add(-time.Minute)) // enforced

	const serial = "SERIAL-LATE"
	p := reg.Register("p-late", nil, &protocol.RegisterMessage{PublicKey: "k"})
	p.Mu().Lock()
	p.AttestationResult = &attestation.VerificationResult{SerialNumber: serial, PublicKey: "k"}
	p.TrustLevel = registry.TrustHardware
	p.Mu().Unlock()

	// A genuinely-Apple-signed SIP-off cert (Valid + serial match + SIP off) is
	// the reachable definitive case on the late path. Hand-build the parsed
	// result to bypass the un-forgeable real-root chain check.
	mdaResult := &attestation.MDAResult{
		Valid:             true,
		DeviceSerial:      serial,
		SIPEnabled:        false,
		SecureBootEnabled: true,
		BootState:         "Full Security",
	}

	done := make(chan struct{})
	go func() {
		srv.attributeAndApplyMDA(mdaResult, [][]byte{{0x01}})
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("attributeAndApplyMDA deadlocked — registry write-lock method called inside ForEachProvider's RLock")
	}

	got := reg.GetProvider("p-late")
	if got == nil {
		t.Fatal("provider vanished")
	}
	got.Mu().Lock()
	status := got.Status
	got.Mu().Unlock()
	if status != registry.StatusUntrusted {
		t.Errorf("a late Apple-signed SIP-off cert must untrust the provider under enforcement; status=%v", status)
	}
}

// The legacy constant nonce — what every pre-#302 cert carries, and what an
// attacker can compute (sha256 of the public SE key) — must never satisfy the
// routing verdict, regardless of cert age.
func TestEvaluateMDA_LegacyConstantNeverRoutes(t *testing.T) {
	seed := []byte("test-seed-0123456789abcdef0123456789abcdef")
	now := time.Unix(1_770_000_000, 0)
	const serial, seKey = "SERIAL", "se-key"

	m := &attestation.MDAResult{
		Valid:             true,
		DeviceSerial:      serial,
		SIPEnabled:        true,
		SecureBootEnabled: true,
		BootState:         "Full Security",
		FreshnessCode:     attestation.LegacyMDANonce(seKey),
		LeafNotBefore:     now.Add(-time.Hour), // even brand-new
	}
	eval := evaluateMDA(m, serial, seKey, seed, now)
	if eval.SIPVerified {
		t.Fatal("the legacy constant sha256(SE key) nonce must never grant the routing verdict")
	}
	if !eval.SEKeyBound {
		t.Error("legacy nonce still proves key binding (display), just not freshness")
	}
}
