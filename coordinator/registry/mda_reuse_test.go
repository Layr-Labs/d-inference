package registry

import (
	"encoding/json"
	"testing"

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
