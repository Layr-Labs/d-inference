package api

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"io"
	"log/slog"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// restoreSerialSpyStore records the serial used for history restore so a test
// can prove identity candidates never restore by self-reported serial.
type restoreSerialSpyStore struct {
	*store.MemoryStore
	restoreSerials []string
}

func (s *restoreSerialSpyStore) GetProviderForRestore(ctx context.Context, serial, seKey string, excluded []string) (*store.ProviderRecord, error) {
	s.restoreSerials = append(s.restoreSerials, serial)
	return s.MemoryStore.GetProviderForRestore(ctx, serial, seKey, excluded)
}

// registerIdentityCandidateWithDurableChain registers a macOS 27 App Attest
// identity candidate whose serial has a durable MDA chain from an earlier
// session, next to a live connection reporting the same serial. chainSEKey
// selects which SE key the stored chain's FreshnessCode binds; "" binds the
// candidate's own registration SE key.
func registerIdentityCandidateWithDurableChain(t *testing.T, serial, chainSEKey string) (*Server, *registry.Registry, *registry.Provider, *restoreSerialSpyStore) {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	st := &restoreSerialSpyStore{MemoryStore: store.NewMemory(store.Config{})}
	reg := registry.New(logger)
	s := &Server{registry: reg, store: st, logger: logger,
		appAttestShadow: AppAttestShadowConfig{ServingEnabled: true, Environment: "production", RolloutPercent: 100}}

	key := testPublicKeyB64()
	signed := buildTestAttestationJSONWithFields(t, key, "", serial, time.Now(), map[string]interface{}{"osVersion": "27.0"})
	var envelope struct {
		Attestation struct {
			PublicKey string `json:"publicKey"`
		} `json:"attestation"`
	}
	if err := json.Unmarshal(signed, &envelope); err != nil || envelope.Attestation.PublicKey == "" {
		t.Fatalf("attestation fixture: %v", err)
	}
	if chainSEKey == "" {
		chainSEKey = envelope.Attestation.PublicKey
	}
	freshness := sha256.Sum256([]byte(chainSEKey))
	chain, root := mintMDALeafChain(t, serial, freshness[:])
	t.Cleanup(attestation.OverrideRootCAForTest(root))
	chainJSON, _ := json.Marshal(chain)
	if err := st.UpsertProvider(context.Background(), store.ProviderRecord{
		ID: "earlier-session", SerialNumber: serial, AccountID: "account",
		TrustLevel: string(registry.TrustHardware), MDAVerified: true, MDACertChain: chainJSON,
		LastSeen: time.Now().Add(-time.Hour),
	}); err != nil {
		t.Fatal(err)
	}

	old := reg.Register("old", nil, &protocol.RegisterMessage{})
	old.SetAttestationResult(&attestation.VerificationResult{Valid: true, SerialNumber: serial, PublicKey: "old-se"})
	r := &protocol.RegisterMessage{PublicKey: key, Version: "0.9.9", AppAttestProtocol: 3, Attestation: signed}
	p := reg.Register("current", nil, r)
	t.Cleanup(func() { reg.Disconnect("current"); reg.Disconnect("old") })
	if !s.appAttestIdentityCandidate(r, "account") {
		t.Fatal("fixture is not an identity candidate")
	}
	p.RequireVerifiedMachineIdentity()
	if err := s.verifyProviderAttestation(context.Background(), p.ID, p, r, "account"); err != nil {
		t.Fatal(err)
	}
	return s, reg, p, st
}

// An identity candidate stages the durable chain but gains mda_verified only
// after hardware trust, and only because the chain binds its own SE key.
// Serial-based duplicate eviction and history restore stay skipped.
func TestIdentityCandidateRegainsMDAFromDurableChainAfterHardwareTrust(t *testing.T) {
	s, reg, p, st := registerIdentityCandidateWithDurableChain(t, "SERIAL-27", "")
	if reg.GetProvider("old") == nil {
		t.Fatal("identity candidate evicted a duplicate by self-reported serial")
	}
	if len(st.restoreSerials) != 1 || st.restoreSerials[0] != "" {
		t.Fatalf("identity candidate restored history by serial: %q", st.restoreSerials)
	}
	if len(p.StagedMDAChain()) == 0 {
		t.Fatal("identity candidate did not stage the durable MDA chain")
	}
	ar := p.GetAttestationResult()
	if s.attachCachedMDAProof(p.ID, p, *ar) || mdaVerified(p) {
		t.Fatal("staged chain attached before hardware trust")
	}
	p.SetAttested(true, registry.TrustHardware)
	if !s.attachCachedMDAProof(p.ID, p, *ar) || !mdaVerified(p) {
		t.Fatal("identity candidate did not regain mda_verified from its SE-key-bound chain")
	}
}

// A chain earned by a different SE key (another machine claiming this serial,
// or a rotated key) is staged as a candidate but never attaches.
func TestIdentityCandidateRejectsDurableChainForDifferentSEKey(t *testing.T) {
	s, _, p, _ := registerIdentityCandidateWithDurableChain(t, "SERIAL-27", "other-machine-se-key")
	if len(p.StagedMDAChain()) == 0 {
		t.Fatal("fixture chain was not staged")
	}
	p.SetAttested(true, registry.TrustHardware)
	if s.attachCachedMDAProof(p.ID, p, *p.GetAttestationResult()) || mdaVerified(p) {
		t.Fatal("identity candidate inherited a chain bound to a different SE key")
	}
}
