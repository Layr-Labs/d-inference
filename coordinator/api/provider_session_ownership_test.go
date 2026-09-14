package api

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"nhooyr.io/websocket"
)

type sessionBindingClose struct {
	binding, id, reason string
	status              registry.ProviderStatus
}

type sessionBindingStore struct {
	store.Store
	binding string
	reg     *registry.Registry
	closed  chan<- sessionBindingClose
	onToken func()
	once    sync.Once
}

func (s *sessionBindingStore) GetProviderToken(raw string) (*store.ProviderToken, error) {
	token, err := s.Store.GetProviderToken(raw)
	if err == nil && s.onToken != nil {
		// The read loop itself changes the API binding before its next store
		// operation. No test goroutine races an active read of the field.
		s.once.Do(s.onToken)
	}
	return token, err
}

func (s *sessionBindingStore) CloseProviderSession(ctx context.Context, id, reason string, at time.Time) error {
	observation := sessionBindingClose{binding: s.binding, id: id, reason: reason}
	if p := s.reg.GetProvider(id); p != nil {
		p.Mu().Lock()
		observation.status = p.Status
		p.Mu().Unlock()
	}
	s.closed <- observation
	return s.Store.CloseProviderSession(ctx, id, reason, at)
}

// Registration and teardown use the current API store, while the registry
// keeps its original persistence binding. Both wrappers use a real memory
// store, so the observed close also exercises first-close-wins accounting.
func TestProviderSessionUsesCurrentStoreForSpecificClose(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	const rawToken = "owned-session-binding-token"
	logger := quietLogger()
	memory := store.NewMemory(store.Config{})
	digest := sha256.Sum256([]byte(rawToken))
	if err := memory.CreateProviderToken(&store.ProviderToken{
		TokenHash: hex.EncodeToString(digest[:]), AccountID: "owned-session-account",
		Label: "owned-session", Active: true, CreatedAt: time.Now(),
	}); err != nil {
		t.Fatal(err)
	}
	reg := registry.New(logger)
	closed := make(chan sessionBindingClose, 8)
	initial := &sessionBindingStore{Store: memory, binding: "initial", reg: reg, closed: closed}
	current := &sessionBindingStore{Store: memory, binding: "current", reg: reg, closed: closed}
	srv := NewServer(reg, initial, ServerConfig{}, logger)
	defer srv.Close()
	srv.skipChallenge = true
	rebound := make(chan struct{})
	initial.onToken = func() { srv.store = current; close(rebound) }
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()
	conn, _, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(ts.URL, "http")+"/ws/provider", nil)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.CloseNow()
	data, err := json.Marshal(protocol.RegisterMessage{
		Type: protocol.TypeRegister, AuthToken: rawToken, Backend: registry.BackendMLXSwift,
		Hardware: protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64},
		Models:   []protocol.ModelInfo{{ID: "owned-session-model", ModelType: "chat", Quantization: "4bit"}},
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := conn.Write(ctx, websocket.MessageText, data); err != nil {
		t.Fatal(err)
	}
	select {
	case <-rebound:
	case <-ctx.Done():
		t.Fatal("registration did not resolve the real provider token")
	}
	var providerID string
	waitFor(t, 3*time.Second, "linked provider and open durable session", func() bool {
		ids := reg.ProviderIDs()
		if len(ids) != 1 {
			return false
		}
		p := reg.GetProvider(ids[0])
		if p == nil {
			return false
		}
		p.Mu().Lock()
		linked := p.AccountID == "owned-session-account"
		p.Mu().Unlock()
		rows, err := memory.ListProviderSessionsOverlapping(ctx, time.Now().Add(-time.Minute), time.Now().Add(time.Minute), time.Hour)
		if !linked || err != nil || len(rows) != 1 || rows[0].DisconnectedAt != nil {
			return false
		}
		providerID = ids[0]
		return rows[0].SessionID == providerID
	})
	if err := conn.Close(websocket.StatusNormalClosure, "owned fixture complete"); err != nil {
		t.Fatal(err)
	}
	select {
	case first := <-closed:
		if first.binding != "current" || first.id != providerID || first.reason != "ws_close_1000" || first.status != registry.StatusOffline {
			t.Fatalf("first durable close = %+v; want current binding, same provider, specific reason, already offline", first)
		}
	case <-ctx.Done():
		t.Fatal("specific durable close was not observed")
	}
	waitFor(t, 3*time.Second, "registry removal preserves specific close", func() bool {
		rows, err := memory.ListProviderSessionsOverlapping(ctx, time.Now().Add(-time.Minute), time.Now().Add(time.Minute), time.Hour)
		return reg.ProviderCount() == 0 && err == nil && len(rows) == 1 && rows[0].DisconnectedAt != nil && rows[0].DisconnectReason == "ws_close_1000"
	})
}
