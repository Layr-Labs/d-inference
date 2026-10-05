package provider_test

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/testkit"
	"nhooyr.io/websocket"
)

type retryRestoreStore struct {
	store.Store
	lookupFailures, reputationFailures   int
	lookups, reputationReads, tokenReads atomic.Int32
	beforeLookup, beforeReputation       func(context.Context) error
}

func (s *retryRestoreStore) GetProviderForRestore(ctx context.Context, serial, key string, exclude []string) (*store.ProviderRecord, error) {
	n := s.lookups.Add(1)
	if s.beforeLookup != nil {
		if err := s.beforeLookup(ctx); err != nil {
			return nil, err
		}
	}
	if int(n) <= s.lookupFailures {
		return nil, io.ErrUnexpectedEOF
	}
	return s.Store.GetProviderForRestore(ctx, serial, key, exclude)
}

func (s *retryRestoreStore) GetReputation(ctx context.Context, id string) (*store.ReputationRecord, error) {
	n := s.reputationReads.Add(1)
	if s.beforeReputation != nil {
		if err := s.beforeReputation(ctx); err != nil {
			return nil, err
		}
	}
	if int(n) <= s.reputationFailures {
		return nil, io.ErrUnexpectedEOF
	}
	return s.Store.GetReputation(ctx, id)
}

func (s *retryRestoreStore) GetProviderToken(token string) (*store.ProviderToken, error) {
	s.tokenReads.Add(1)
	return s.Store.GetProviderToken(token)
}

func TestProviderRestoreExhaustionEndsRegistrationBeforeDuplicateEviction(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	st := &retryRestoreStore{Store: memory.NewMemory(store.Config{}), lookupFailures: 100}
	reg := registry.New(logger)
	srv := api.NewServer(reg, st, api.ServerConfig{}, logger)
	defer srv.Close()
	pubKey := testkit.PublicKeyB64()
	evidence := testkit.CreateAttestationJSON(t, pubKey)
	verified, err := attestation.VerifyJSON(evidence)
	if err != nil || !verified.Valid {
		t.Fatalf("invalid test evidence: %v", err)
	}
	old := reg.Register("existing", nil, &protocol.RegisterMessage{})
	old.SetAttestationResult(&verified)
	old.CompleteProviderStateRestore()
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	conn, _, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(ts.URL, "http")+"/ws/provider", nil)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.CloseNow()
	msg, _ := json.Marshal(protocol.RegisterMessage{Type: protocol.TypeRegister, PublicKey: pubKey, Attestation: evidence, AuthToken: "test-token"})
	if err := conn.Write(ctx, websocket.MessageText, msg); err != nil {
		t.Fatal(err)
	}
	for {
		if _, _, err := conn.Read(ctx); err != nil {
			if websocket.CloseStatus(err) != websocket.StatusTryAgainLater {
				t.Fatalf("wrong close status: %v", err)
			}
			break
		}
	}
	if st.lookups.Load() != 3 || st.tokenReads.Load() != 0 {
		t.Fatalf("unbounded retries or registration continued: lookups=%d token_reads=%d", st.lookups.Load(), st.tokenReads.Load())
	}
	if reg.GetProvider(old.ID) != old {
		t.Fatal("failed reconnect evicted existing session")
	}
}
