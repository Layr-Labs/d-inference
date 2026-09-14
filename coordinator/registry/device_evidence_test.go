package registry

import (
	"testing"

	"github.com/eigeninference/d-inference/coordinator/attestation"
)

// TestSetMDAProofIfHardware covers the atomic late-MDA attach that fixes the
// TOCTOU + data race in the onMDA callback: MDA proof is attached only to a
// connection currently holding hardware trust, with a matching serial, and the
// trust check + writes happen under a single lock.
func TestSetMDAProofIfHardware(t *testing.T) {
	chain := [][]byte{[]byte("der")}
	mda := &attestation.MDAResult{DeviceSerial: "S1", DeviceUDID: "U1"}

	// hardware + matching serial → attaches.
	hw := New(testLogger()).Register("hw", nil, testRegisterMessage())
	hw.Mu().Lock()
	hw.TrustLevel = TrustHardware
	hw.AttestationResult = &attestation.VerificationResult{SerialNumber: "S1"}
	hw.Mu().Unlock()
	if !hw.SetMDAProofIfHardware(chain, mda) {
		t.Fatal("expected attach on hardware provider with matching serial")
	}
	if !hw.MDAVerified || len(hw.MDACertChain) != 1 || hw.MDAResult == nil {
		t.Error("hardware provider should have MDA proof set")
	}

	// self_signed → must NOT attach (this is the drift/TOCTOU guard).
	ss := New(testLogger()).Register("ss", nil, testRegisterMessage())
	ss.Mu().Lock()
	ss.TrustLevel = TrustSelfSigned
	ss.AttestationResult = &attestation.VerificationResult{SerialNumber: "S1"}
	ss.Mu().Unlock()
	if ss.SetMDAProofIfHardware(chain, mda) {
		t.Error("must NOT attach MDA proof to a self_signed provider")
	}
	if ss.MDAVerified {
		t.Error("self_signed provider must not have MDAVerified set")
	}

	// hardware but serial mismatch → must NOT attach (different device).
	mm := New(testLogger()).Register("mm", nil, testRegisterMessage())
	mm.Mu().Lock()
	mm.TrustLevel = TrustHardware
	mm.AttestationResult = &attestation.VerificationResult{SerialNumber: "OTHER"}
	mm.Mu().Unlock()
	if mm.SetMDAProofIfHardware(chain, mda) {
		t.Error("must NOT attach MDA proof when the MDA serial does not match")
	}
}
