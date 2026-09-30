package service

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/e2e"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"nhooyr.io/websocket"
)

// connectedShadowProvider registers a provider whose writer sends frames over a
// loopback websocket. The returned client conn reads what the coordinator sent.
func connectedShadowProvider(t *testing.T, endpoint string) (*registry.Provider, *websocket.Conn) {
	t.Helper()
	serverConns := make(chan *websocket.Conn, 1)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, err := websocket.Accept(w, r, nil)
		if err != nil {
			t.Errorf("accept websocket: %v", err)
			return
		}
		serverConns <- conn
	}))
	t.Cleanup(server.Close)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	client, _, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(server.URL, "http"), nil)
	if err != nil {
		t.Fatalf("dial websocket: %v", err)
	}
	t.Cleanup(func() { _ = client.Close(websocket.StatusNormalClosure, "done") })
	var serverConn *websocket.Conn
	select {
	case serverConn = <-serverConns:
	case <-ctx.Done():
		t.Fatal("server websocket not accepted")
	}
	r := registry.New(slog.New(slog.NewTextHandler(io.Discard, nil)))
	p := r.Register("connected", serverConn, &protocol.RegisterMessage{PublicKey: endpoint})
	t.Cleanup(func() { r.Disconnect(p.ID) })
	return p, client
}

func readShadowFrame(t *testing.T, client *websocket.Conn) protocol.AppAttestShadowPayload {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_, data, err := client.Read(ctx)
	if err != nil {
		t.Fatalf("read shadow frame: %v", err)
	}
	var m protocol.AppAttestShadowMessage
	if err := json.Unmarshal(data, &m); err != nil || m.Type != protocol.TypeAppAttestShadow {
		t.Fatalf("unexpected frame %s: %v", data, err)
	}
	return m.Payload
}

func newSendSession(st store.Store, p *registry.Provider, endpoint string) *Session {
	s := &Service{store: st, logger: slog.New(slog.NewTextHandler(io.Discard, nil)),
		config: Config{AppID: "TEST.app", Environment: "production"}}
	return &Session{s: s, provider: p, id: "session", owner: "owner", account: "account", publicKey: endpoint,
		protocolVersion: 3, key: &store.AppAttestShadowKey{KeyID: rotationKeyID(7)}}
}

// bareStore exposes only the base Store interface, so optional App Attest
// capabilities are absent.
type bareStore struct{ store.Store }

type failingEnrollmentSave struct{ *store.MemoryStore }

func (*failingEnrollmentSave) SaveAppAttestEnrollment(context.Context, store.AppAttestEnrollment) error {
	return errors.New("write failed")
}

func TestAttestSendRecordsEnrollmentBeforeChallengeReachesProvider(t *testing.T) {
	endpoint := base64.StdEncoding.EncodeToString(make([]byte, 32))
	p, client := connectedShadowProvider(t, endpoint)
	mem := store.NewMemory(store.Config{})
	x := newSendSession(mem, p, endpoint)
	if !x.send(context.Background(), "attest") {
		t.Fatalf("attest send failed: %s", x.lastOutcome)
	}
	if x.expected != "attestation" || x.lastOutcome != "attempted" || x.storageSlotHeld {
		t.Fatalf("expected=%q outcome=%q slotHeld=%v", x.expected, x.lastOutcome, x.storageSlotHeld)
	}
	got := readShadowFrame(t, client)
	if got.Action != "attest" || got.Session != "session" || got.Challenge != x.challenge || got.KeyID != x.key.KeyID ||
		got.ProtocolVersion != 3 || got.AccountScope != x.accountScope() || got.Environment != "production" || got.EncryptedChallenge != nil {
		t.Fatalf("attest frame %+v", got)
	}
	e, err := mem.GetAppAttestEnrollment(context.Background(), "session")
	if err != nil || e == nil {
		t.Fatalf("enrollment not stored: %v", err)
	}
	if e.Challenge != x.challenge || e.Owner != "owner" || e.KeyID != x.key.KeyID || e.AppID != "TEST.app" ||
		e.PublicKey != endpoint || e.AccountScope != x.accountScope() || e.ProtocolVersion != 3 {
		t.Fatalf("enrollment context %+v", e)
	}
}

func TestAssertSendEncryptsChallengeToEndpointKey(t *testing.T) {
	keys, err := e2e.GenerateSessionKeys()
	if err != nil {
		t.Fatal(err)
	}
	endpoint := base64.StdEncoding.EncodeToString(keys.PublicKey[:])
	p, client := connectedShadowProvider(t, endpoint)
	x := newSendSession(store.NewMemory(store.Config{}), p, endpoint)
	x.dropped.Store(3)
	x.assertionArchived = true
	if !x.send(context.Background(), "assert") {
		t.Fatalf("assert send failed: %s", x.lastOutcome)
	}
	if x.expected != "assertion" || x.proofDropBaseline != 3 || x.assertionArchived {
		t.Fatal("assert did not start a new archive baseline")
	}
	got := readShadowFrame(t, client)
	if got.Action != "assert" || got.Challenge != "" || got.EncryptedChallenge == nil {
		t.Fatalf("assert frame must carry only the encrypted challenge: %+v", got)
	}
	plain, err := e2e.Decrypt(&e2e.EncryptedPayload{EphemeralPublicKey: got.EncryptedChallenge.EphemeralPublicKey, Ciphertext: got.EncryptedChallenge.Ciphertext}, keys)
	if err != nil || string(plain) != x.challenge {
		t.Fatalf("challenge not readable by the endpoint key: %q %v", plain, err)
	}
}

func TestSendFailuresStopBeforeProviderIO(t *testing.T) {
	endpoint := base64.StdEncoding.EncodeToString(make([]byte, 32))
	// No provider writer: any frame that reached EnqueueText would report
	// send_failed instead of the expected earlier outcome.
	p := newSessionProvider(endpoint, "se")
	t.Run("enrollment storage missing", func(t *testing.T) {
		x := newSendSession(bareStore{}, p, endpoint)
		if x.send(context.Background(), "attest") || x.lastOutcome != "storage_unavailable" {
			t.Fatalf("outcome %q", x.lastOutcome)
		}
	})
	t.Run("storage slots busy", func(t *testing.T) {
		mem := store.NewMemory(store.Config{})
		x := newSendSession(mem, p, endpoint)
		x.s.storageOnce.Do(func() { x.s.storageSlots = make(chan struct{}, 1) })
		x.s.storageSlots <- struct{}{}
		if x.send(context.Background(), "attest") || x.lastOutcome != "storage_busy" {
			t.Fatalf("outcome %q", x.lastOutcome)
		}
		if e, _ := mem.GetAppAttestEnrollment(context.Background(), "session"); e != nil {
			t.Fatal("busy storage still wrote an enrollment")
		}
	})
	t.Run("enrollment write fails", func(t *testing.T) {
		x := newSendSession(&failingEnrollmentSave{store.NewMemory(store.Config{})}, p, endpoint)
		if x.send(context.Background(), "attest") || x.lastOutcome != "storage_error" {
			t.Fatalf("outcome %q", x.lastOutcome)
		}
		if x.storageSlotHeld || len(x.s.storageSlots) != 0 {
			t.Fatal("failed enrollment leaked its storage slot")
		}
	})
	t.Run("endpoint key not 32 bytes", func(t *testing.T) {
		x := newSendSession(store.NewMemory(store.Config{}), p, base64.StdEncoding.EncodeToString(make([]byte, 16)))
		if x.send(context.Background(), "assert") || x.lastOutcome != "encryption_key" {
			t.Fatalf("outcome %q", x.lastOutcome)
		}
	})
	t.Run("stopped writer", func(t *testing.T) {
		x := newSendSession(store.NewMemory(store.Config{}), p, endpoint)
		if x.send(context.Background(), "prepare") || x.lastOutcome != "send_failed" || x.expected != "ready" {
			t.Fatalf("outcome %q expected %q", x.lastOutcome, x.expected)
		}
	})
}
