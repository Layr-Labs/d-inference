package api

// Billing integration tests for Darkbloom coordinator.
//
// These tests exercise the full billing flow end-to-end: consumer balance
// checking, inference charging, referral reward distribution, device auth
// linking, and multi-node account earnings.

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"nhooyr.io/websocket"
)

type failingCreditStore struct {
	store.Store
}

func billingTestServer(t *testing.T) (*Server, *store.MemoryStore, *payments.Ledger) {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	srv.challengeInterval = 200 * time.Millisecond

	ledger := srv.ledger

	// Enable billing with mock mode (no on-chain verification).
	billingSvc := billing.NewService(st, ledger, logger, billing.Config{
		MockMode:             true,
		ReferralSharePercent: 20,
	})
	srv.SetBilling(billingSvc)

	// Credit the default test consumer ("test-key") with $100 so
	// the pre-flight balance check passes. Tests that need zero
	// balance should use a different consumer key.
	_ = st.Credit(testConsumerID, 100_000_000, store.LedgerDeposit, "test-setup")

	return srv, st, ledger
}

// setupProviderForBilling connects a provider, sets trust, records challenge
// success, and returns the WebSocket connection, provider ID, and public key.
func setupProviderForBilling(t *testing.T, ctx context.Context, ts *httptest.Server, reg *registry.Registry, model string) (*websocket.Conn, string, string) {
	t.Helper()
	pubKey := testPublicKeyB64()
	models := []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}}

	conn := connectProviderWithToken(t, ctx, ts.URL, models, pubKey, "")

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

func setupProviderForBillingNoPayoutDestination(t *testing.T, ctx context.Context, ts *httptest.Server, reg *registry.Registry, model string) (*websocket.Conn, string, string) {
	t.Helper()
	pubKey := testPublicKeyB64()
	models := []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}}

	conn := connectProvider(t, ctx, ts.URL, models, pubKey)

	for _, id := range reg.ProviderIDs() {
		reg.SetTrustLevel(id, registry.TrustHardware)
		reg.RecordChallengeSuccess(id)
	}

	providerIDs := reg.ProviderIDs()
	if len(providerIDs) == 0 {
		t.Fatal("no providers registered")
	}

	return conn, providerIDs[len(providerIDs)-1], pubKey
}

// serveOneInference handles challenges and exactly one inference request on the
// provider WebSocket, sending a chunk and complete message with the given usage.
// pubKey should match the key the provider registered with (used in challenge responses).
func serveOneInference(ctx context.Context, t *testing.T, conn *websocket.Conn, pubKey string, usage protocol.UsageInfo) <-chan struct{} {
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
				resp := makeValidChallengeResponse(data, pubKey)
				conn.Write(ctx, websocket.MessageText, resp)

			case protocol.TypeInferenceRequest:
				var inferReq protocol.InferenceRequestMessage
				json.Unmarshal(data, &inferReq)

				writeEncryptedTestChunk(t, ctx, conn, inferReq, pubKey,
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

// serveChunkThenProviderError commits the request with one encrypted chunk, then
// returns a provider error instead of a completion message.
func serveChunkThenProviderError(ctx context.Context, t *testing.T, conn *websocket.Conn, pubKey string, statusCode int) <-chan struct{} {
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
				resp := makeValidChallengeResponse(data, pubKey)
				conn.Write(ctx, websocket.MessageText, resp)

			case protocol.TypeInferenceRequest:
				var inferReq protocol.InferenceRequestMessage
				json.Unmarshal(data, &inferReq)

				writeEncryptedTestChunk(t, ctx, conn, inferReq, pubKey,
					`data: {"id":"chatcmpl-1","choices":[{"delta":{"content":"partial"}}]}`+"\n\n")

				errMsg := protocol.InferenceErrorMessage{
					Type:       protocol.TypeInferenceError,
					RequestID:  inferReq.RequestID,
					Error:      "backend failed after first token",
					StatusCode: statusCode,
				}
				errData, _ := json.Marshal(errMsg)
				conn.Write(ctx, websocket.MessageText, errData)
				return

			case protocol.TypeCancel:
				// Ignore cancels sent after the error response.
			}
		}
	}()

	return done
}

// sendInferenceRequest sends a consumer chat completion request and drains the
// response body. Returns the HTTP status code.
func sendInferenceRequest(t *testing.T, ctx context.Context, tsURL, model, apiKey string) int {
	t.Helper()
	chatBody := `{"model":"` + model + `","messages":[{"role":"user","content":"hello"}],"stream":true}`
	httpReq, _ := http.NewRequestWithContext(ctx, http.MethodPost, tsURL+"/v1/chat/completions", strings.NewReader(chatBody))
	httpReq.Header.Set("Authorization", "Bearer "+apiKey)

	resp, err := http.DefaultClient.Do(httpReq)
	if err != nil {
		t.Fatalf("http request: %v", err)
	}
	defer resp.Body.Close()
	io.ReadAll(resp.Body)

	return resp.StatusCode
}

// sha256HexStr computes SHA-256 of a string and returns hex encoding.
func sha256HexStr(s string) string {
	h := sha256.Sum256([]byte(s))
	return hex.EncodeToString(h[:])
}
