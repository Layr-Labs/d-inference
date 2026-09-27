package service

import (
	"context"
	"encoding/json"
	"errors"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
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
	p := newSessionProvider("endpoint", "se")
	p.AttestationResult = &attestation.VerificationResult{Valid: true, PublicKey: "se", EncryptionPublicKey: p.PublicKey, SerialNumber: "claimed"}
	p.MDAResult = &attestation.MDAResult{Valid: true, DeviceSerial: "apple-serial"}
	p.MDAVerified = true
	st := &captureInventory{}
	x := &machineInventorySession{s: &Service{}, p: p, store: st, observation: store.MachineObservation{SessionID: p.ID, AccountID: "authenticated"}}
	x.capture(false)
	if st.observation.SEKey != "se" || st.observation.VerifiedSerial != "" {
		t.Fatal("serial claim became physical identity")
	}
	p.TrustLevel = registry.TrustHardware
	p.SEKeyBound = true
	x.capture(false)
	if st.observation.VerifiedSerial != "apple-serial" {
		t.Fatal("verified alias missing")
	}
	p.AttestationResult.Valid = false
	x.capture(false)
	if st.observation.SEKey != "" || st.observation.VerifiedSerial != "" {
		t.Fatal("invalid identity retained")
	}
}

func TestAppAttestEnrollmentRecoveryUsesOriginalTranscriptAndOwner(t *testing.T) {
	st := store.NewMemory(store.Config{})
	now := time.Now()
	x := &Session{s: &Service{store: st, config: Config{AppID: "TEST.app", Environment: "production"}}, owner: "owner", account: "account", id: "new", challenge: "new challenge", publicKey: "new endpoint", protocolVersion: 2, key: &store.AppAttestShadowKey{KeyID: "key"}}
	e := store.AppAttestEnrollment{ID: "original", Owner: "owner", KeyID: "key", CreatedAt: now, AppID: "TEST.app", Environment: "production", Challenge: "old challenge", PublicKey: "old endpoint", AccountScope: x.accountScope()}
	if err := st.SaveAppAttestEnrollment(context.Background(), e); err != nil {
		t.Fatal(err)
	}
	reply := protocol.AppAttestShadowPayload{ProtocolVersion: 2, EnrollmentSession: "original", Status: &protocol.AppAttestStatus{OSVersion: "27"}}
	hash, err := x.clientHash(context.Background(), "attest", reply)
	if err != nil || hash != protocol.AppAttestShadowHashV2("attest", e.ID, e.Environment, e.KeyID, e.Challenge, e.PublicKey, e.AccountScope, reply.Status) {
		t.Fatalf("recovery %v", err)
	}
	x.owner = "attacker"
	if _, err = x.clientHash(context.Background(), "attest", reply); err == nil {
		t.Fatal("cross-owner recovery")
	}
}

type failedEvidenceArchive struct{}

func (failedEvidenceArchive) BeginAppAttestEvidence(context.Context, store.AppAttestEvidence) error {
	return errors.New("offline")
}
func (failedEvidenceArchive) CompleteAppAttestEvidence(context.Context, string, store.AppAttestDecision) (string, error) {
	return "", errors.New("offline")
}

func TestAppAttestArchiveFailureDoesNotAdvanceCounter(t *testing.T) {
	st := store.NewMemory(store.Config{})
	key := &store.AppAttestShadowKey{KeyID: "key", Owner: "owner"}
	_, _ = st.InsertAppAttestShadowKey(context.Background(), *key)
	p := newSessionProvider("endpoint", "se")
	x := &Session{s: &Service{}, provider: p, store: st, archive: failedEvidenceArchive{}, key: key, expected: "assertion"}
	before, _ := json.Marshal(p.GetTrustLevel())
	if got := x.handle(context.Background(), protocol.AppAttestShadowPayload{Action: "assertion", Proof: "invalid"}); got != "stop" {
		t.Fatal(got)
	}
	after, _ := json.Marshal(p.GetTrustLevel())
	stored, _ := st.GetAppAttestShadowKey(context.Background(), "key")
	if string(before) != string(after) || stored.Counter != 0 {
		t.Fatal("archive failure mutated serving/key state")
	}
}
