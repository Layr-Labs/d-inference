package api

// Regression for the Codex P2 finding on PR #512 (registry.go:993): account
// linkage resolves the auth token AFTER verifyProviderAttestation in the
// registration flow, so a provider whose stable identity is the ACCOUNT
// fallback (Open Mode — no attestation) never got its fault key bound. Every
// breaker then keyed by the session UUID and reset on reconnect. The read
// loop now re-binds right after linkage (RebindStableFaultKey); this test
// exercises the REAL WebSocket registration path on both sessions.

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"nhooyr.io/websocket"
)

func TestAccountLinkedFaultStateSurvivesReconnect(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(ts.Close)

	const acct = "acct-open-mode"
	const rawToken = "eigeninference-pt-account-fault-key-test"
	if err := st.CreateProviderToken(&store.ProviderToken{
		TokenHash: sha256Hash(rawToken),
		AccountID: acct,
		Active:    true,
	}); err != nil {
		t.Fatalf("create provider token: %v", err)
	}

	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/ws/provider"
	connect := func() (*websocket.Conn, string) {
		t.Helper()
		conn, _, err := websocket.Dial(ctx, wsURL, nil)
		if err != nil {
			t.Fatalf("websocket dial: %v", err)
		}
		regMsg := protocol.RegisterMessage{
			Type:      protocol.TypeRegister,
			Hardware:  protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64},
			Models:    []protocol.ModelInfo{{ID: "test-model", ModelType: "chat", Quantization: "4bit"}},
			Backend:   "mlx-swift",
			AuthToken: rawToken,
		}
		regData, _ := json.Marshal(regMsg)
		if err := conn.Write(ctx, websocket.MessageText, regData); err != nil {
			t.Fatalf("write register: %v", err)
		}
		var id string
		waitFor(t, 5*time.Second, "provider registered and account-linked", func() bool {
			ids := reg.ProviderIDs()
			if len(ids) != 1 {
				return false
			}
			id = ids[0]
			return reg.GetProviderStableIdentity(id) == "acct:"+acct
		})
		return conn, id
	}

	// Session 1 registers without attestation: the linked account is its ONLY
	// stable identity. Open the node-health breaker against it.
	conn1, sess1 := connect()
	for i := 0; i < 8; i++ {
		reg.RecordProviderOutcome(sess1, false, 500, "internal error")
	}
	if !reg.ProviderBreakerOpen(sess1) {
		t.Fatal("breaker must be open for session 1 after a consecutive fault streak")
	}

	conn1.Close(websocket.StatusNormalClosure, "churn")
	waitFor(t, 5*time.Second, "session 1 disconnected", func() bool {
		return reg.ProviderCount() == 0
	})

	// Reconnect: fresh session UUID, same account token. The open breaker must
	// re-attach via the acct: binding — without the account-linkage rebind the
	// fresh session resolves to its own UUID and reads a clean record.
	conn2, sess2 := connect()
	defer conn2.CloseNow()
	if sess2 == sess1 {
		t.Fatalf("expected a fresh session id, got %q twice", sess1)
	}
	waitFor(t, 5*time.Second, "breaker state re-attached to the new session", func() bool {
		return reg.ProviderBreakerOpen(sess2)
	})
}

func TestProviderLinkMigratesUnlinkedPublicKeyEarnings(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()
	defer srv.Close()

	const (
		accountID = "linked-earnings-account"
		rawToken  = "eigeninference-pt-linked-earnings"
		earned    = int64(75_000)
	)
	publicKey := testPublicKeyB64()
	if err := st.CreditWithdrawable(publicKey, earned, store.LedgerPayout, "unlinked-job"); err != nil {
		t.Fatal(err)
	}
	if err := st.CreateProviderToken(&store.ProviderToken{
		TokenHash: sha256Hash(rawToken), AccountID: accountID, Active: true,
	}); err != nil {
		t.Fatal(err)
	}
	connection, _, err := websocket.Dial(
		ctx,
		"ws"+strings.TrimPrefix(ts.URL, "http")+"/ws/provider",
		nil,
	)
	if err != nil {
		t.Fatal(err)
	}
	defer connection.CloseNow()
	registration, _ := json.Marshal(protocol.RegisterMessage{
		Type:     protocol.TypeRegister,
		Hardware: protocol.Hardware{ChipName: "Apple M3 Max", MemoryGB: 64},
		Models:   []protocol.ModelInfo{{ID: "model", ModelType: "chat", Quantization: "4bit"}},
		Backend:  "mlx-swift", PublicKey: publicKey, AuthToken: rawToken,
		EncryptedResponseChunks: true,
	})
	if err := connection.Write(ctx, websocket.MessageText, registration); err != nil {
		t.Fatal(err)
	}
	waitFor(t, 5*time.Second, "unlinked earnings migrated", func() bool {
		return st.GetBalance(publicKey) == 0 &&
			st.GetBalance(accountID) == earned &&
			st.GetWithdrawableBalance(accountID) == earned
	})
}
