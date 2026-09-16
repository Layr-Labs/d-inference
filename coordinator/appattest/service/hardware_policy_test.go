package service

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestAppAttestHardwareClaimsMustBeSignedAndMatchRegistration(t *testing.T) {
	h := protocol.Hardware{MachineModel: "Mac17,6", ChipName: "Apple M5 Max", MemoryGB: 128, CPUCores: protocol.CPUCores{Total: 18, Performance: 12, Efficiency: 6}, GPUCores: 40}
	s := &protocol.AppAttestStatus{MachineModel: h.MachineModel, Chip: h.ChipName, MemoryGB: "128", CPUTotal: "18", CPUPerformance: "12", CPUEfficiency: "6", GPUCores: "40"}
	if known, matched := appAttestHardwareComparison(3, s, h); !known || !matched {
		t.Fatal("matching signed claims rejected")
	}
	if known, _ := appAttestHardwareComparison(2, s, h); known {
		t.Fatal("v2 ignores these fields, cannot authenticate them")
	}
	h.MemoryGB = 1024
	if known, matched := appAttestHardwareComparison(3, s, h); !known || matched {
		t.Fatal("registration memory inflation not detected")
	}
	s.GPUCores = ""
	if known, _ := appAttestHardwareComparison(3, s, h); known {
		t.Fatal("partial hardware treated as complete")
	}
	x := &Session{in: make(chan protocol.AppAttestShadowPayload, 2)}
	x.offer(protocol.AppAttestShadowPayload{Status: &protocol.AppAttestStatus{MemoryGB: strings.Repeat("x", 129)}})
	if len(x.in) != 0 || x.dropped.Load() != 1 {
		t.Fatal("new fields bypassed size bound")
	}
}

func TestAppAttestV3RecoversV2EnrollmentWithOriginalTranscript(t *testing.T) {
	st := store.NewMemory(store.Config{})
	ctx := context.Background()
	x := &Session{s: &Service{store: st, config: Config{AppID: "TEST.app", Environment: "production"}}, owner: "owner", account: "account", id: "new", challenge: "new", publicKey: "new endpoint", protocolVersion: 3, key: &store.AppAttestShadowKey{KeyID: "key"}}
	old := store.AppAttestEnrollment{ID: "old", Owner: "owner", KeyID: "key", CreatedAt: time.Now(), AppID: "TEST.app", Environment: "production", Challenge: "old nonce", PublicKey: "old endpoint", AccountScope: x.accountScope()}
	if err := st.SaveAppAttestEnrollment(ctx, old); err != nil {
		t.Fatal(err)
	}
	p := protocol.AppAttestShadowPayload{ProtocolVersion: 3, EnrollmentSession: "old", Status: &protocol.AppAttestStatus{OSVersion: "27"}}
	hash, err := x.clientHash(ctx, "attest", p)
	expected := protocol.AppAttestShadowHashV2("attest", old.ID, old.Environment, old.KeyID, old.Challenge, old.PublicKey, old.AccountScope, p.Status)
	if err != nil || hash != expected {
		t.Fatal("v2 recovery was reinterpreted as v3", err)
	}
	p.EnrollmentSession = ""
	fresh, err := x.clientHash(ctx, "assert", p)
	if err != nil || fresh != protocol.AppAttestShadowHashV3("assert", x.id, old.Environment, old.KeyID, x.challenge, x.publicKey, x.accountScope(), p.Status) {
		t.Fatal("fresh assertion did not use v3", err)
	}
}
