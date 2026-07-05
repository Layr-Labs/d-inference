package registry

import (
	"encoding/json"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// TestRestoreProviderStateStagesMDAChain verifies that a reconnect stages the
// durable Apple-signed MDA cert chain from the store WITHOUT surfacing it as a
// verified proof. The staged chain is what lets the hardware-grant path reuse a
// still-valid attestation instead of forcing a fresh, rate-limited request.
func TestRestoreProviderStateStagesMDAChain(t *testing.T) {
	reg := New(testLogger())
	p := reg.Register("p1", nil, testRegisterMessage())

	chain := [][]byte{[]byte("leaf-der-bytes")}
	chainJSON, _ := json.Marshal(chain)
	rec := &store.ProviderRecord{
		ID:           "p1",
		TrustLevel:   string(TrustHardware),
		MDAVerified:  true,
		MDACertChain: chainJSON,
	}

	reg.RestoreProviderState(p, rec)

	// MDAVerified must stay false (drift guard) — the proof is re-earned this
	// connection, not resurrected.
	p.Mu().Lock()
	mda := p.MDAVerified
	p.Mu().Unlock()
	if mda {
		t.Error("MDAVerified must be false after restore (drift guard)")
	}

	// ...but the chain is staged for local re-verification at hardware-grant.
	staged := p.StagedMDAChain()
	if len(staged) != 1 || string(staged[0]) != "leaf-der-bytes" {
		t.Errorf("StagedMDAChain = %v, want the stored chain", staged)
	}
}

// TestRestoreProviderStateNoMDAChain confirms an absent stored chain leaves the
// staging slot empty (so the reuse path declines and a fresh request is made).
func TestRestoreProviderStateNoMDAChain(t *testing.T) {
	reg := New(testLogger())
	p := reg.Register("p1", nil, testRegisterMessage())
	reg.RestoreProviderState(p, &store.ProviderRecord{ID: "p1", TrustLevel: string(TrustSelfSigned)})
	if staged := p.StagedMDAChain(); staged != nil {
		t.Errorf("StagedMDAChain = %v, want nil", staged)
	}
}

// TestSetMDAProofIfHardwareBound covers the binding matrix: a proof is attached
// only when the provider holds hardware trust AND the proof binds to this machine
// by SE-key freshness OR by a matching attested serial.
func TestSetMDAProofIfHardwareBound(t *testing.T) {
	chain := [][]byte{[]byte("der")}

	newHardwareProvider := func(serial string) *Provider {
		reg := New(testLogger())
		p := reg.Register("p", nil, testRegisterMessage())
		p.SetAttestationResult(&attestation.VerificationResult{SerialNumber: serial, PublicKey: "PUB"})
		p.TrustLevel = TrustHardware
		return p
	}

	t.Run("se-key bound, serial omitted -> attached", func(t *testing.T) {
		p := newHardwareProvider("SERIAL-A")
		ok := p.SetMDAProofIfHardwareBound(chain, &attestation.MDAResult{Valid: true, DeviceSerial: ""}, true)
		if !ok {
			t.Fatal("expected attach with SE-key binding and omitted serial")
		}
		p.Mu().Lock()
		defer p.Mu().Unlock()
		if !p.MDAVerified || !p.SEKeyBound {
			t.Errorf("MDAVerified=%v SEKeyBound=%v, want both true", p.MDAVerified, p.SEKeyBound)
		}
	})

	t.Run("serial match, not se-key bound -> attached", func(t *testing.T) {
		p := newHardwareProvider("SERIAL-A")
		ok := p.SetMDAProofIfHardwareBound(chain, &attestation.MDAResult{Valid: true, DeviceSerial: "SERIAL-A"}, false)
		if !ok {
			t.Fatal("expected attach on serial match")
		}
	})

	t.Run("no binding -> rejected", func(t *testing.T) {
		p := newHardwareProvider("SERIAL-A")
		ok := p.SetMDAProofIfHardwareBound(chain, &attestation.MDAResult{Valid: true, DeviceSerial: "SERIAL-B"}, false)
		if ok {
			t.Fatal("expected reject when neither SE key nor serial binds (relay/device-swap)")
		}
		p.Mu().Lock()
		defer p.Mu().Unlock()
		if p.MDAVerified {
			t.Error("MDAVerified must stay false on a rejected attach")
		}
	})

	t.Run("self_signed -> rejected even when bound", func(t *testing.T) {
		p := newHardwareProvider("SERIAL-A")
		p.TrustLevel = TrustSelfSigned
		ok := p.SetMDAProofIfHardwareBound(chain, &attestation.MDAResult{Valid: true, DeviceSerial: "SERIAL-A"}, true)
		if ok {
			t.Fatal("expected reject when not hardware-trusted")
		}
	})

	t.Run("nil result -> rejected", func(t *testing.T) {
		p := newHardwareProvider("SERIAL-A")
		if p.SetMDAProofIfHardwareBound(chain, nil, true) {
			t.Fatal("expected reject for nil mdaResult")
		}
	})
}
