package provider_test

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/testkit"
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

func TestRegistrationResolvesAccountOnceBeforeIdentityClassification(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	st := &identityCohortStore{Store: memory.NewMemory(store.Config{})}
	reg := registry.New(logger)
	s := api.NewServer(reg, st, api.ServerConfig{AppAttestShadow: api.AppAttestShadowConfig{ServingEnabled: true, Environment: "production", RolloutPercent: 100}}, logger)
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
	key := testkit.PublicKeyB64()
	r := protocol.RegisterMessage{Type: protocol.TypeRegister, PublicKey: key, Version: "0.9.4", AppAttestProtocol: 3, AuthToken: "valid-once",
		Attestation: testkit.BuildAttestationJSONWithFields(t, key, "", "serial", time.Now(), map[string]interface{}{"osVersion": "27.0"})}
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
