package api

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

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
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

func TestProviderRestoreRetriesTransientReads(t *testing.T) {
	for _, phase := range []string{"provider", "reputation"} {
		t.Run(phase, func(t *testing.T) {
			base := store.NewMemory(store.Config{})
			if err := base.UpsertProviderWithReputation(context.Background(), store.ProviderRecord{
				ID: "history", SerialNumber: "serial", SEPublicKey: "se", LastSeen: time.Now(),
				AccountID: "owner", LifetimeTokensGenerated: 700,
			}, store.ReputationRecord{TotalJobs: 12}); err != nil {
				t.Fatal(err)
			}
			st := &retryRestoreStore{Store: base}
			if phase == "provider" {
				st.lookupFailures = 1
			} else {
				st.reputationFailures = 1
			}
			logger := slog.New(slog.NewTextHandler(io.Discard, nil))
			reg := registry.New(logger)
			reg.SetStore(st)
			p := reg.Register("new", nil, &protocol.RegisterMessage{})
			srv := &Server{registry: reg, store: st, logger: logger}
			if err := srv.restorePersistedProviderState(context.Background(), p, "serial", "se"); err != nil {
				t.Fatal(err)
			}
			p.Mu().Lock()
			defer p.Mu().Unlock()
			if st.lookups.Load() != 2 || p.AccountID != "owner" || p.Stats.TokensGenerated != 700 || p.Reputation.TotalJobs != 12 {
				t.Fatalf("recovery abandoned after transient %s error: lookups=%d account=%q tokens=%d jobs=%d", phase, st.lookups.Load(), p.AccountID, p.Stats.TokensGenerated, p.Reputation.TotalJobs)
			}
		})
	}
}

func TestProviderRestoreDeadlineIncludesReputation(t *testing.T) {
	for _, phase := range []string{"provider", "reputation"} {
		t.Run(phase, func(t *testing.T) {
			base := store.NewMemory(store.Config{})
			if err := base.UpsertProvider(context.Background(), store.ProviderRecord{ID: "history", SerialNumber: "serial", AccountID: "owner"}); err != nil {
				t.Fatal(err)
			}
			block := func(ctx context.Context) error { <-ctx.Done(); return ctx.Err() }
			st := &retryRestoreStore{Store: base}
			if phase == "provider" {
				st.beforeLookup = block
			} else {
				st.beforeReputation = block
			}
			logger := slog.New(slog.NewTextHandler(io.Discard, nil))
			reg := registry.New(logger)
			reg.SetStore(st)
			p := reg.Register("new", nil, &protocol.RegisterMessage{})
			srv := &Server{registry: reg, store: st, logger: logger}
			ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
			defer cancel()
			started := time.Now()
			err := srv.restorePersistedProviderState(ctx, p, "serial", "se")
			if !errors.Is(err, context.DeadlineExceeded) || time.Since(started) > time.Second || st.lookups.Load() != 1 {
				t.Fatalf("%s read escaped registration deadline: %v, attempts=%d", phase, err, st.lookups.Load())
			}
			p.Mu().Lock()
			defer p.Mu().Unlock()
			if p.AccountID != "" {
				t.Fatal("failed read partially restored state")
			}
		})
	}
}

func TestProviderRestoreDisconnectedSessionStopsRetry(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	st := &retryRestoreStore{Store: store.NewMemory(store.Config{})}
	reg := registry.New(logger)
	reg.SetStore(st)
	p := reg.Register("new", nil, &protocol.RegisterMessage{})
	st.beforeLookup = func(context.Context) error { reg.Disconnect(p.ID); return io.ErrUnexpectedEOF }
	srv := &Server{registry: reg, store: st, logger: logger}
	if err := srv.restorePersistedProviderState(context.Background(), p, "serial", "se"); !errors.Is(err, context.Canceled) || st.lookups.Load() != 1 {
		t.Fatalf("disconnected session retried: %v, attempts=%d", err, st.lookups.Load())
	}
}

func TestProviderRestoreExhaustionEndsRegistrationBeforeDuplicateEviction(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	st := &retryRestoreStore{Store: store.NewMemory(store.Config{}), lookupFailures: 100}
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	defer srv.Close()
	pubKey := testPublicKeyB64()
	evidence := createTestAttestationJSON(t, pubKey)
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
	if st.lookups.Load() != providerRestoreAttempts || st.tokenReads.Load() != 0 {
		t.Fatalf("unbounded retries or registration continued: lookups=%d token_reads=%d", st.lookups.Load(), st.tokenReads.Load())
	}
	if reg.GetProvider(old.ID) != old {
		t.Fatal("failed reconnect evicted existing session")
	}
}
