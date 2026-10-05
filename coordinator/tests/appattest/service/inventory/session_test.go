package inventory_test

import (
	"context"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/internal/appattest/inventory"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type captureInventory struct{ observation store.MachineObservation }

func (c *captureInventory) ObserveMachine(_ context.Context, o store.MachineObservation) (store.MachineIdentity, error) {
	c.observation = o
	return store.MachineIdentity{ID: "machine", Assurance: o.Source}, nil
}
func (*captureInventory) RecordAppAttestEvent(context.Context, store.AppAttestEvent) error {
	return nil
}

func TestMachineInventoryRequiresSEBoundMDAForSerialAlias(t *testing.T) {
	p := &registry.Provider{ID: "p1", PublicKey: "endpoint"}
	p.AttestationResult = &attestation.VerificationResult{Valid: true, PublicKey: "se", EncryptionPublicKey: p.PublicKey, SerialNumber: "claimed"}
	p.MDAResult = &attestation.MDAResult{Valid: true, DeviceSerial: "apple-serial"}
	p.MDAVerified = true
	st := &captureInventory{}
	x := inventory.NewSession(inventory.SessionDependencies{Store: st, Provider: p}, store.MachineObservation{SessionID: p.ID, AccountID: "authenticated"})
	x.Capture(false)
	if st.observation.SEKey != "se" || st.observation.VerifiedSerial != "" {
		t.Fatal("serial claim became physical identity")
	}
	p.TrustLevel = registry.TrustHardware
	p.SEKeyBound = true
	x.Capture(false)
	if st.observation.VerifiedSerial != "apple-serial" {
		t.Fatal("verified alias missing")
	}
	p.AttestationResult.Valid = false
	x.Capture(false)
	if st.observation.SEKey != "" || st.observation.VerifiedSerial != "" {
		t.Fatal("invalid identity retained")
	}
}
