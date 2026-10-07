package testkit

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"nhooyr.io/websocket"
)

// NewBilling enables isolated mock billing and funds the default consumer key.
func NewBilling(t *testing.T) (*Fixture, *payments.Ledger) {
	t.Helper()
	f := New(t, api.ServerConfig{})
	f.Server.SetChallengeInterval(200 * time.Millisecond)
	ledger := payments.NewLedger(f.Store)
	f.Server.SetBilling(billing.NewService(f.Store, ledger, slog.New(slog.DiscardHandler), billing.Config{MockMode: true}))
	if err := f.Store.Credit(store.LegacyAccountID("test-key"), 100_000_000, store.LedgerDeposit, "test-setup"); err != nil {
		t.Fatal(err)
	}
	return f, ledger
}

// SetProviderOwner assigns the account used by self-route ownership checks.
func SetProviderOwner(reg *registry.Registry, accountID string) {
	for _, id := range reg.ProviderIDs() {
		if p := reg.GetProvider(id); p != nil {
			p.Mu().Lock()
			p.AccountID = accountID
			p.Mu().Unlock()
		}
	}
}

// SetupProviderForBilling connects a provider, sets trust, records challenge
// success, and returns the WebSocket connection, provider ID, and public key.
func SetupProviderForBilling(t *testing.T, ctx context.Context, ts *httptest.Server, reg *registry.Registry, model string) (*websocket.Conn, string, string) {
	t.Helper()
	pubKey := PublicKeyB64()
	models := []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}}

	conn := ConnectProviderWithToken(t, ctx, ts.URL, models, pubKey, "")

	for _, id := range reg.ProviderIDs() {
		reg.SetTrustLevel(id, registry.TrustHardware)
		reg.RecordChallengeSuccess(id)
	}

	providerIDs := reg.ProviderIDs()
	if len(providerIDs) == 0 {
		t.Fatal("no providers registered")
	}

	// Set AccountID for payout destination (required since wallet-based payouts removed).
	for _, id := range providerIDs {
		if p := reg.GetProvider(id); p != nil {
			p.Mu().Lock()
			p.AccountID = "test-account-" + id
			p.Mu().Unlock()
		}
	}

	return conn, providerIDs[len(providerIDs)-1], pubKey
}

// ServeOneInference handles challenges and exactly one inference request on the
// provider WebSocket, sending a chunk and complete message with the given usage.
// pubKey should match the key the provider registered with (used in challenge responses).
func ServeOneInference(ctx context.Context, t *testing.T, conn *websocket.Conn, pubKey string, usage protocol.UsageInfo) <-chan struct{} {
	t.Helper()
	done := make(chan struct{})

	go func() {
		defer close(done)
		for {
			_, data, err := conn.Read(ctx)
			if err != nil {
				return
			}
			var env struct {
				Type string `json:"type"`
			}
			json.Unmarshal(data, &env)

			switch env.Type {
			case protocol.TypeAttestationChallenge:
				resp := MakeValidChallengeResponse(data, pubKey)
				conn.Write(ctx, websocket.MessageText, resp)

			case protocol.TypeInferenceRequest:
				var inferReq protocol.InferenceRequestMessage
				json.Unmarshal(data, &inferReq)

				WriteEncryptedChunk(t, ctx, conn, inferReq, pubKey,
					`data: {"id":"chatcmpl-1","choices":[{"delta":{"content":"ok"}}]}`+"\n\n")

				complete := protocol.InferenceCompleteMessage{
					Type:      protocol.TypeInferenceComplete,
					RequestID: inferReq.RequestID,
					Usage:     usage,
				}
				completeData, _ := json.Marshal(complete)
				conn.Write(ctx, websocket.MessageText, completeData)
				return

			case protocol.TypeCancel:
				// Ignore cancel messages sent after completion.
			}
		}
	}()

	return done
}
