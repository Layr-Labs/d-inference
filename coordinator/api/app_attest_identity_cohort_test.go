package api

import (
	"context"
	"crypto/sha256"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"nhooyr.io/websocket"
)

type identityCohortStore struct {
	store.Store
	tokenReads atomic.Int32
	serial     string
	mdaReads   int
}

func (s *identityCohortStore) GetProviderToken(string) (*store.ProviderToken, error) {
	if s.tokenReads.Add(1) != 1 {
		return nil, errors.New("token changed after first lookup")
	}
	return &store.ProviderToken{AccountID: "account", Label: "test", Active: true}, nil
}

func (s *identityCohortStore) GetProviderForRestore(_ context.Context, serial, _ string, _ []string) (*store.ProviderRecord, error) {
	s.serial = serial
	return nil, nil
}

func (s *identityCohortStore) GetMDAChainBySerial(_ context.Context, _ string) (json.RawMessage, error) {
	s.mdaReads++
	return json.RawMessage(`["c3RhZ2VkLWR1cmFibGUtY2hhaW4="]`), nil
}

func TestIdentityCohortControlsLegacyRecoveryAndDuplicateEviction(t *testing.T) {
	excluded := ""
	for i := 0; excluded == ""; i++ {
		candidate := fmt.Sprintf("account-%d", i)
		hash := sha256.Sum256([]byte("app-attest-rollout-account-v1\x00" + candidate))
		if binary.BigEndian.Uint32(hash[:4])%100 >= 50 {
			excluded = candidate
		}
	}
	for _, tc := range []struct {
		name, environment, account, os string
		percent                        int
		candidate                      bool
	}{
		{"included", "production", "account", "27.0", 100, true},
		{"excluded account", "production", excluded, "27.0", 50, false},
		{"disabled rollout", "production", "account", "27.0", 0, false},
		{"development", "development", "account", "27.0", 100, false},
		{"older macOS", "production", "account", "26.0", 100, false},
		{"unvalidated account", "production", "", "27.0", 100, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			logger := slog.New(slog.NewTextHandler(io.Discard, nil))
			st := &identityCohortStore{Store: store.NewMemory(store.Config{})}
			reg := registry.New(logger)
			s := &Server{registry: reg, store: st, logger: logger,
				appAttestShadow: AppAttestShadowConfig{ServingEnabled: true, Environment: tc.environment, RolloutPercent: tc.percent}}
			key := testPublicKeyB64()
			old := reg.Register("old", nil, &protocol.RegisterMessage{})
			old.SetAttestationResult(&attestation.VerificationResult{Valid: true, SerialNumber: "same-serial", PublicKey: "old-se"})
			r := &protocol.RegisterMessage{PublicKey: key, Version: "0.9.4", AppAttestProtocol: 3, AuthToken: "must-not-be-reloaded",
				Attestation: buildTestAttestationJSONWithFields(t, key, "", "same-serial", time.Now(), map[string]interface{}{"osVersion": tc.os})}
			p := reg.Register("current", nil, r)
			t.Cleanup(func() { reg.Disconnect("current"); reg.Disconnect("old") })
			if got := s.appAttestIdentityCandidate(r, tc.account); got != tc.candidate {
				t.Fatal("candidate fixture")
			}
			if tc.candidate {
				p.RequireVerifiedMachineIdentity()
			}
			if err := s.verifyProviderAttestation(context.Background(), p.ID, p, r, tc.account); err != nil {
				t.Fatal(err)
			}
			if st.tokenReads.Load() != 0 {
				t.Fatal("attestation phase reloaded an already validated token")
			}
			if tc.candidate {
				if st.serial != "" || st.mdaReads != 0 || reg.GetProvider("old") == nil {
					t.Fatal("candidate used unverified serial identity")
				}
			} else if st.serial != "same-serial" || st.mdaReads != 1 || reg.GetProvider("old") != nil || len(p.StagedMDAChain()) == 0 {
				t.Fatalf("legacy recovery lost: serial=%q MDA reads=%d duplicate=%v staged=%d", st.serial, st.mdaReads, reg.GetProvider("old") != nil, len(p.StagedMDAChain()))
			}
		})
	}
}

func TestRegistrationResolvesAccountOnceBeforeIdentityClassification(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	st := &identityCohortStore{Store: store.NewMemory(store.Config{})}
	reg := registry.New(logger)
	s := NewServer(reg, st, ServerConfig{AppAttestShadow: AppAttestShadowConfig{ServingEnabled: true, Environment: "production", RolloutPercent: 100}}, logger)
	s.SetSkipChallenge(true)
	t.Cleanup(s.Close)
	server := httptest.NewServer(s.Handler())
	t.Cleanup(server.Close)
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	conn, _, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(server.URL, "http")+"/ws/provider", nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close(websocket.StatusNormalClosure, "done") })
	key := testPublicKeyB64()
	r := protocol.RegisterMessage{Type: protocol.TypeRegister, PublicKey: key, Version: "0.9.4", AppAttestProtocol: 3, AuthToken: "valid-once",
		Attestation: buildTestAttestationJSONWithFields(t, key, "", "serial", time.Now(), map[string]interface{}{"osVersion": "27.0"})}
	raw, _ := json.Marshal(r)
	if err := conn.Write(ctx, websocket.MessageText, raw); err != nil {
		t.Fatal(err)
	}
	for ctx.Err() == nil {
		for _, id := range reg.ProviderIDs() {
			p := reg.GetProvider(id)
			if p == nil {
				continue
			}
			p.Mu().Lock()
			account := p.AccountID
			p.Mu().Unlock()
			if account == "account" {
				if st.tokenReads.Load() != 1 {
					t.Fatal("registration reloaded the token")
				}
				return
			}
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal("validated account was not linked after registration")
}
