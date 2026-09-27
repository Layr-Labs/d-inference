package api

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

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"nhooyr.io/websocket"
)

type frameCoverageStore struct {
	*store.MemoryStore
	observed chan store.MachineObservation
	proofs   atomic.Int32
}

func (s *frameCoverageStore) ObserveMachine(ctx context.Context, o store.MachineObservation) (store.MachineIdentity, error) {
	id, err := s.MemoryStore.ObserveMachine(ctx, o)
	if err == nil {
		s.observed <- o
	}
	return id, err
}

func (s *frameCoverageStore) BeginAppAttestEvidence(ctx context.Context, e store.AppAttestEvidence) error {
	s.proofs.Add(1)
	return s.MemoryStore.BeginAppAttestEvidence(ctx, e)
}

func TestAppAttestOversizedFramesReachInventoryThroughWebSocket(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	st := &frameCoverageStore{MemoryStore: store.NewMemory(store.Config{}), observed: make(chan store.MachineObservation, 16)}
	reg := registry.New(logger)
	s := NewServer(reg, st, ServerConfig{AppAttestShadow: AppAttestShadowConfig{Enabled: true, AppID: "TEST.app", Environment: "production"}}, logger)
	s.SetSkipChallenge(true)
	t.Cleanup(s.Close)
	ts := httptest.NewServer(s.Handler())
	t.Cleanup(ts.Close)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	conn, _, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(ts.URL, "http")+"/ws/provider", nil)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.CloseNow()
	write := func(frame string) {
		t.Helper()
		if err := conn.Write(ctx, websocket.MessageText, []byte(frame)); err != nil {
			t.Fatal(err)
		}
	}
	oversized := `{"type":"app_attest_shadow","payload":{"action":"assertion","proof":"` + strings.Repeat("A", 50*1024) + `"}}`
	// No negotiated session yet: must not panic or attribute this to a later one.
	write(oversized)
	registration, _ := json.Marshal(protocol.RegisterMessage{Type: protocol.TypeRegister, PublicKey: testPublicKeyB64(), Version: "0.9.3", AppAttestProtocol: 2})
	write(string(registration))
	var first store.MachineObservation
	select {
	case first = <-st.observed:
	case <-ctx.Done():
		t.Fatal("registration did not reach inventory")
	}
	p := reg.GetProvider(first.SessionID)
	if p == nil {
		t.Fatal("provider did not register")
	}
	p.Mu().Lock()
	before, trust := p.LastHeartbeat, p.TrustLevel
	p.Mu().Unlock()
	write(oversized)
	// Escaped discriminator takes the decoder fallback; count it exactly once too.
	write(strings.Replace(oversized, `"app_attest_shadow"`, `"app_attest_\u0073hadow"`, 1))
	write(`{"type":"heartbeat","active_model":42}`) // unrelated decoder error
	write(`{"type":"heartbeat"}`)
	ticker := time.NewTicker(time.Millisecond)
	defer ticker.Stop()
	for {
		p.Mu().Lock()
		continued, unchanged := p.LastHeartbeat.After(before), p.TrustLevel == trust
		p.Mu().Unlock()
		if !unchanged {
			t.Fatal("frame refusal changed authoritative trust")
		}
		if continued {
			break
		}
		select {
		case <-ticker.C:
		case <-ctx.Done():
			t.Fatal("oversized shadow frame blocked normal heartbeats")
		}
	}
	if err := conn.Close(websocket.StatusNormalClosure, "test complete"); err != nil {
		t.Fatal(err)
	}
	for {
		select {
		case o := <-st.observed:
			if !o.Disconnected {
				continue
			}
			if o.ShadowDropped != 2 {
				t.Fatalf("persisted refused-frame count = %d, want 2", o.ShadowDropped)
			}
			if st.proofs.Load() != 0 {
				t.Fatal("oversized proof entered the archive")
			}
			return
		case <-ctx.Done():
			t.Fatal("disconnect did not persist inventory coverage")
		}
	}
}
