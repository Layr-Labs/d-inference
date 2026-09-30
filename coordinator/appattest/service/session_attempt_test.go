package service

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"io"
	"log/slog"
	"net"
	"net/http"
	"sync"
	"testing"
	"testing/synctest"
	"time"

	"github.com/eigeninference/d-inference/coordinator/appattest"
	"github.com/eigeninference/d-inference/coordinator/internal/e2e"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/fxamacker/cbor/v2"
	"nhooyr.io/websocket"
)

// pipeListener serves exactly one in-memory connection. Everything stays in
// the synctest bubble, so fake time can pass the exchange's jitter and
// 90-second response timers instantly.
type pipeListener struct {
	conns chan net.Conn
	once  sync.Once
	done  chan struct{}
}

func (l *pipeListener) Accept() (net.Conn, error) {
	select {
	case c := <-l.conns:
		return c, nil
	case <-l.done:
		return nil, net.ErrClosed
	}
}

func (l *pipeListener) Close() error   { l.once.Do(func() { close(l.done) }); return nil }
func (l *pipeListener) Addr() net.Addr { return pipeAddr{} }

type pipeAddr struct{}

func (pipeAddr) Network() string { return "pipe" }
func (pipeAddr) String() string  { return "pipe" }

// pipeWebSocket returns a server-side conn for the provider writer and the
// client conn that reads what the coordinator sent. Call it inside a bubble.
func pipeWebSocket(t *testing.T) (server, client *websocket.Conn, closeAll func()) {
	t.Helper()
	serverSide, clientSide := net.Pipe()
	ln := &pipeListener{conns: make(chan net.Conn, 1), done: make(chan struct{})}
	ln.conns <- serverSide
	accepted := make(chan *websocket.Conn, 1)
	srv := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c, err := websocket.Accept(w, r, nil)
		if err != nil {
			t.Errorf("accept: %v", err)
			return
		}
		accepted <- c
	})}
	go func() { _ = srv.Serve(ln) }()
	transport := &http.Transport{DialContext: func(context.Context, string, string) (net.Conn, error) { return clientSide, nil }}
	client, _, err := websocket.Dial(context.Background(), "ws://pipe/", &websocket.DialOptions{HTTPClient: &http.Client{Transport: transport}})
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	server = <-accepted
	return server, client, func() {
		_ = client.CloseNow()
		_ = server.CloseNow()
		_ = srv.Close()
		transport.CloseIdleConnections()
	}
}

// attemptHarness runs a real exchange worker against an in-memory provider
// socket. The test plays the provider: it reads challenges and offers replies.
type attemptHarness struct {
	s        *Service
	x        *Session
	mem      *store.MemoryStore
	client   *websocket.Conn
	endpoint *e2e.SessionKeys
	device   *ecdsa.PrivateKey
	keyID    string
	mu       sync.Mutex
	events   []map[string]any
}

// newAttemptHarness must be called inside a synctest bubble.
func newAttemptHarness(t *testing.T, st store.Store) *attemptHarness {
	t.Helper()
	h := &attemptHarness{mem: store.NewMemory(store.Config{}), keyID: rotationKeyID(4)}
	if st == nil {
		st = h.mem
	}
	var err error
	if h.endpoint, err = e2e.GenerateSessionKeys(); err != nil {
		t.Fatal(err)
	}
	if h.device, err = ecdsa.GenerateKey(elliptic.P256(), rand.Reader); err != nil {
		t.Fatal(err)
	}
	if _, err := h.mem.InsertAppAttestShadowKey(context.Background(), store.AppAttestShadowKey{KeyID: h.keyID, Owner: "owner", AccountID: "account",
		AppID: "TEST.app", Environment: "production", PublicKey: elliptic.Marshal(h.device.Curve, h.device.X, h.device.Y)}); err != nil {
		t.Fatal(err)
	}
	server, client, closeAll := pipeWebSocket(t)
	h.client = client
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	r := registry.New(logger)
	endpoint := base64.StdEncoding.EncodeToString(h.endpoint.PublicKey[:])
	p := r.Register("connected", server, &protocol.RegisterMessage{PublicKey: endpoint})
	t.Cleanup(func() {
		r.Disconnect(p.ID)
		closeAll()
	})
	h.s = New(context.Background(), Config{AppID: "TEST.app", Environment: "production"}, Dependencies{Store: st, Logger: logger, Emit: func(fields map[string]any) {
		h.mu.Lock()
		h.events = append(h.events, fields)
		h.mu.Unlock()
	}})
	h.x = &Session{s: h.s, provider: p, id: "first-session", owner: "owner", account: "account", publicKey: endpoint, protocolVersion: 3,
		in: make(chan protocol.AppAttestShadowPayload, 2), store: h.mem, archive: h.mem,
		verifier: appattest.New(appattest.Policy{AppID: "TEST.app", Environment: "production"})}
	return h
}

func (h *attemptHarness) read(t *testing.T) protocol.AppAttestShadowPayload {
	t.Helper()
	_, data, err := h.client.Read(context.Background())
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	var m protocol.AppAttestShadowMessage
	if err := json.Unmarshal(data, &m); err != nil {
		t.Fatal(err)
	}
	return m.Payload
}

func (h *attemptHarness) challenge(t *testing.T, frame protocol.AppAttestShadowPayload) string {
	t.Helper()
	if frame.Action != "assert" || frame.EncryptedChallenge == nil {
		t.Fatalf("expected an encrypted assert challenge, got %+v", frame)
	}
	plain, err := e2e.Decrypt(&e2e.EncryptedPayload{EphemeralPublicKey: frame.EncryptedChallenge.EphemeralPublicKey, Ciphertext: frame.EncryptedChallenge.Ciphertext}, h.endpoint)
	if err != nil {
		t.Fatal(err)
	}
	return string(plain)
}

// assertion signs the challenge the way a provider's App Attest key does.
func (h *attemptHarness) assertion(t *testing.T, frame protocol.AppAttestShadowPayload, counter byte) protocol.AppAttestShadowPayload {
	t.Helper()
	challenge := h.challenge(t, frame)
	status := testShadowStatus()
	endpoint := base64.StdEncoding.EncodeToString(h.endpoint.PublicKey[:])
	hash := protocol.AppAttestShadowHashV3("assert", frame.Session, "production", h.keyID, challenge, endpoint, frame.AccountScope, status)
	rp := sha256.Sum256([]byte("TEST.app"))
	auth := append(append([]byte{}, rp[:]...), 0, 0, 0, 0, counter)
	signed := sha256.Sum256(append(auth, hash[:]...))
	signed = sha256.Sum256(signed[:])
	signature, err := ecdsa.SignASN1(rand.Reader, h.device, signed[:])
	if err != nil {
		t.Fatal(err)
	}
	body, err := cbor.Marshal(map[string]any{"signature": signature, "authenticatorData": auth})
	if err != nil {
		t.Fatal(err)
	}
	return protocol.AppAttestShadowPayload{Session: frame.Session, Action: "assertion", Result: "ok", KeyID: h.keyID, Challenge: challenge,
		Proof: base64.StdEncoding.EncodeToString(body), ProtocolVersion: 3, Status: status}
}

func (h *attemptHarness) outcomes() []string {
	h.mu.Lock()
	defer h.mu.Unlock()
	var out []string
	for _, e := range h.events {
		out = append(out, e["stage"].(string)+":"+e["outcome"].(string))
	}
	return out
}

func contains(list []string, want string) bool {
	for _, v := range list {
		if v == want {
			return true
		}
	}
	return false
}

func TestExchangeWorkerAssertsWaitsReassertsAndRecovers(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		h := newAttemptHarness(t, nil)
		ctx, cancel := context.WithCancel(context.Background())
		done := make(chan struct{})
		go func() {
			defer close(done)
			h.x.run(ctx)
		}()

		prepare := h.read(t)
		if prepare.Action != "prepare" || prepare.Session != "first-session" {
			t.Fatalf("prepare frame %+v", prepare)
		}
		// A late callback from an older attempt is archived without ending
		// this exchange.
		h.x.Offer(protocol.AppAttestShadowPayload{Session: "older-session", Action: "ready", Result: "ok", KeyID: h.keyID})
		h.x.Offer(protocol.AppAttestShadowPayload{Session: prepare.Session, Action: "ready", Result: "ok", KeyID: h.keyID})
		first := h.read(t)
		start := time.Now()
		h.x.Offer(h.assertion(t, first, 1))
		synctest.Wait()
		if key, _ := h.mem.GetAppAttestShadowKey(context.Background(), h.keyID); key == nil || key.Counter != 1 {
			t.Fatalf("verified assertion did not advance the durable counter: %+v", key)
		}
		// During the assertion interval a duplicate of the same session is
		// archived and does not move the next challenge.
		h.x.Offer(protocol.AppAttestShadowPayload{Session: prepare.Session, Action: "ready", Result: "ok", KeyID: h.keyID})
		second := h.read(t)
		if waited := time.Since(start); waited != shadowAssertionInterval {
			t.Fatalf("next assertion after %v, want %v", waited, shadowAssertionInterval)
		}
		if h.challenge(t, second) == h.challenge(t, first) {
			t.Fatal("assertion challenge reused")
		}
		// No reply: the response timer ends the attempt and recovery starts a
		// new session after a short retry delay.
		retry := h.read(t)
		if retry.Action != "prepare" || retry.Session == prepare.Session {
			t.Fatalf("recovery frame %+v", retry)
		}
		cancel()
		<-done

		got := h.outcomes()
		for _, want := range []string{"protocol:unexpected_reply", "ready:reported_supported", "assertion:verified", "assertion:timeout", "recovery:retry_scheduled", "ready:disconnected"} {
			if !contains(got, want) {
				t.Fatalf("missing %s in %v", want, got)
			}
		}
	})
}

func TestExchangeWorkerStopsOnClientFailureAndBusyVerifier(t *testing.T) {
	t.Run("client reports unsupported", func(t *testing.T) {
		synctest.Test(t, func(t *testing.T) {
			h := newAttemptHarness(t, nil)
			done := make(chan struct{})
			go func() { defer close(done); h.x.runAttempt(context.Background()) }()
			prepare := h.read(t)
			h.x.Offer(protocol.AppAttestShadowPayload{Session: prepare.Session, Action: "ready", Result: "unsupported"})
			<-done
			if h.x.lastOutcome != "unsupported" || !contains(h.outcomes(), "ready:unsupported") {
				t.Fatalf("outcome %q events %v", h.x.lastOutcome, h.outcomes())
			}
		})
	})
	t.Run("verifier busy", func(t *testing.T) {
		synctest.Test(t, func(t *testing.T) {
			h := newAttemptHarness(t, nil)
			for range cap(h.s.verifierSlots) {
				h.s.verifierSlots <- struct{}{}
			}
			done := make(chan struct{})
			go func() { defer close(done); h.x.runAttempt(context.Background()) }()
			prepare := h.read(t)
			h.x.Offer(protocol.AppAttestShadowPayload{Session: prepare.Session, Action: "ready", Result: "ok", KeyID: h.keyID})
			<-done
			if h.x.lastOutcome != "verifier_busy" || !contains(h.outcomes(), "archive:verifier_busy") {
				t.Fatalf("outcome %q events %v", h.x.lastOutcome, h.outcomes())
			}
		})
	})
	t.Run("next challenge cannot be sent", func(t *testing.T) {
		synctest.Test(t, func(t *testing.T) {
			// An unknown key needs attest, whose enrollment write fails.
			h := newAttemptHarness(t, &failingEnrollmentSave{store.NewMemory(store.Config{})})
			h.x.store = h.s.store.(store.AppAttestShadowStore)
			done := make(chan struct{})
			go func() { defer close(done); h.x.runAttempt(context.Background()) }()
			prepare := h.read(t)
			h.x.Offer(protocol.AppAttestShadowPayload{Session: prepare.Session, Action: "ready", Result: "ok", KeyID: rotationKeyID(9)})
			<-done
			if h.x.lastOutcome != "storage_error" {
				t.Fatalf("outcome %q", h.x.lastOutcome)
			}
		})
	})
}

func TestExchangeWorkerObservesDisconnectAndMissingReady(t *testing.T) {
	t.Run("cancelled before first challenge", func(t *testing.T) {
		synctest.Test(t, func(t *testing.T) {
			h := newAttemptHarness(t, nil)
			ctx, cancel := context.WithCancel(context.Background())
			cancel()
			h.x.runAttempt(ctx)
			// With zero jitter the prepare frame may still be sent first; either
			// way the attempt ends as a disconnect and never reaches ready.
			if h.x.lastOutcome != "disconnected" || contains(h.outcomes(), "ready:reported_supported") {
				t.Fatalf("events %v", h.outcomes())
			}
		})
	})
	t.Run("ready never arrives", func(t *testing.T) {
		synctest.Test(t, func(t *testing.T) {
			h := newAttemptHarness(t, nil)
			done := make(chan struct{})
			go func() { defer close(done); h.x.runAttempt(context.Background()) }()
			h.read(t)
			start := time.Now()
			<-done
			if h.x.lastOutcome != "timeout" || time.Since(start) != shadowResponseTimeout {
				t.Fatalf("outcome %q after %v", h.x.lastOutcome, time.Since(start))
			}
		})
	})
	t.Run("provider writer stopped", func(t *testing.T) {
		synctest.Test(t, func(t *testing.T) {
			h := newAttemptHarness(t, nil)
			h.x.provider = newSessionProvider("endpoint", "se")
			h.x.runAttempt(context.Background())
			if h.x.lastOutcome != "send_failed" {
				t.Fatalf("outcome %q", h.x.lastOutcome)
			}
		})
	})
}
