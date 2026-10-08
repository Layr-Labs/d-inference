package provider_test

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/earningsfloor"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
	"nhooyr.io/websocket"
)

type consentCaptureCall struct {
	consent  earningsfloor.Consent
	deadline time.Time
	err      error
}

// Only delay/fail the injected store boundary. Capture, authentication,
// inventory binding and journaling still run through their real implementations.
type consentCaptureStore struct {
	*memory.MemoryStore
	mu            sync.Mutex
	calls         []consentCaptureCall
	beforeConsent func(context.Context, earningsfloor.Consent) error
	inventoryGate <-chan struct{}
	observed      chan store.MachineObservation
	tokenGate     <-chan struct{}
	tokenEntered  chan struct{}
}

func (s *consentCaptureStore) ObserveAutopilotConsent(ctx context.Context, consent earningsfloor.Consent) (earningsfloor.Enrollment, error) {
	s.mu.Lock()
	before := s.beforeConsent
	s.mu.Unlock()
	var enrollment earningsfloor.Enrollment
	var err error
	if before != nil {
		err = before(ctx, consent)
	}
	if err == nil {
		enrollment, err = s.MemoryStore.ObserveAutopilotConsent(ctx, consent)
	}
	deadline, _ := ctx.Deadline()
	s.mu.Lock()
	s.calls = append(s.calls, consentCaptureCall{consent, deadline, err})
	s.mu.Unlock()
	return enrollment, err
}

func (s *consentCaptureStore) ObserveMachine(ctx context.Context, observation store.MachineObservation) (store.MachineIdentity, error) {
	if s.inventoryGate != nil {
		select {
		case <-s.inventoryGate:
		case <-ctx.Done():
			return store.MachineIdentity{}, ctx.Err()
		}
	}
	identity, err := s.MemoryStore.ObserveMachine(ctx, observation)
	if err == nil {
		s.observed <- observation
	}
	return identity, err
}

func (s *consentCaptureStore) GetProviderToken(token string) (*store.ProviderToken, error) {
	if s.tokenGate != nil {
		s.tokenEntered <- struct{}{}
		<-s.tokenGate
	}
	return s.MemoryStore.GetProviderToken(token)
}

func (s *consentCaptureStore) snapshot() []consentCaptureCall {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]consentCaptureCall(nil), s.calls...)
}

func (s *consentCaptureStore) failBeforeConsent(before func(context.Context, earningsfloor.Consent) error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.beforeConsent = before
}

type consentSocketFixture struct {
	owner  *Owner
	store  *consentCaptureStore
	conn   *websocket.Conn
	closed chan error
	ctx    context.Context
}

const consentCaptureToken = "consent-capture-provider-token"
const consentCaptureAccount = "consent-capture-account"

func newConsentSocket(t *testing.T, st *consentCaptureStore) *consentSocketFixture {
	t.Helper()
	if st == nil {
		st = &consentCaptureStore{}
	}
	st.MemoryStore = memory.NewMemory(store.Config{})
	st.observed = make(chan store.MachineObservation, 32)
	if err := st.CreateProviderToken(&store.ProviderToken{
		TokenHash: providerTokenHash(consentCaptureToken), AccountID: consentCaptureAccount, Active: true,
	}); err != nil {
		t.Fatal(err)
	}
	logger := quietLogger()
	// Keep capability discovery on the same decorator path as production.
	cached := store.NewCached(st, store.CacheConfig{})
	owner := newProviderFixture(t, Dependencies{Registry: registry.New(logger), Store: cached, Logger: logger})
	owner.trust.SetSkipChallenge(true)
	ts := httptest.NewServer(http.HandlerFunc(owner.HandleProviderWS))
	t.Cleanup(ts.Close)
	ctx, cancel := context.WithTimeout(t.Context(), 20*time.Second)
	t.Cleanup(cancel)
	conn, _, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(ts.URL, "http")+"/ws/provider", nil)
	if err != nil {
		t.Fatal(err)
	}
	f := &consentSocketFixture{owner: owner, store: st, conn: conn, closed: make(chan error, 1), ctx: ctx}
	go func() {
		for {
			if _, _, err := conn.Read(ctx); err != nil {
				f.closed <- err
				return
			}
		}
	}()
	t.Cleanup(func() {
		cleanup, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		if !owner.CloseProviderConnections(cleanup) {
			t.Error("consent capture handler did not stop")
		}
		_ = conn.CloseNow()
	})
	return f
}

func savedConsent(enabled bool) *protocol.ModelAutopilotState {
	return &protocol.ModelAutopilotState{
		Protocol: protocol.ModelAutopilotProtocol, ConsentEnabled: &enabled,
		CachedOnly: true, Revision: "selected", SelectedModels: []string{"cached-model"},
	}
}

func (f *consentSocketFixture) write(t *testing.T, message any) {
	t.Helper()
	data, err := json.Marshal(message)
	if err != nil {
		t.Fatal(err)
	}
	if err := f.conn.Write(f.ctx, websocket.MessageText, data); err != nil {
		t.Fatal(err)
	}
}

// The serial reader only handles this ping after the preceding data frame.
func (f *consentSocketFixture) sync(t *testing.T) {
	t.Helper()
	if err := f.conn.Ping(f.ctx); err != nil {
		t.Fatal(err)
	}
}

func (f *consentSocketFixture) register(t *testing.T, state *protocol.ModelAutopilotState) {
	t.Helper()
	f.write(t, protocol.RegisterMessage{Type: protocol.TypeRegister, AuthToken: consentCaptureToken, ModelAutopilot: state})
	f.sync(t)
}

func (f *consentSocketFixture) heartbeat(t *testing.T, state *protocol.ModelAutopilotState, seq uint64) {
	t.Helper()
	f.write(t, protocol.HeartbeatMessage{Type: protocol.TypeHeartbeat, ModelAutopilot: state, BackendCapacity: &protocol.BackendCapacity{CapacitySeq: seq}})
	f.sync(t)
}

func (f *consentSocketFixture) bind(t *testing.T, declaration earningsfloor.Consent, account string) store.MachineIdentity {
	t.Helper()
	id, err := f.store.MemoryStore.ObserveMachine(t.Context(), store.MachineObservation{
		SessionID: declaration.SessionID, AccountID: account, SEKey: "verified-test-key", At: time.Now().UTC(),
	})
	if err != nil {
		t.Fatal(err)
	}
	return id
}

func (f *consentSocketFixture) enrollments(t *testing.T) []earningsfloor.Enrollment {
	t.Helper()
	rows, err := f.store.AutopilotRewardEnrollments(t.Context(), "", 100)
	if err != nil {
		t.Fatal(err)
	}
	return rows
}
