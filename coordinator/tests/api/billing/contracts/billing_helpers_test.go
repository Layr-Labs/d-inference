package billing_test

// Billing integration tests for Darkbloom coordinator.
//
// These tests exercise the full billing flow end-to-end: consumer balance
// checking, inference charging, referral reward distribution, device auth
// linking, and multi-node account earnings.

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/api/types"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/testkit"
	"nhooyr.io/websocket"
)

func billingTestServer(t *testing.T) (*billingFixture, *memory.MemoryStore, *payments.Ledger) {
	t.Helper()
	f, ledger := testkit.NewBilling(t)
	srv := &billingFixture{Server: f.Server, registry: f.Registry, logger: slog.New(slog.DiscardHandler), sessions: testkit.NewSessions(t, f.Server, f.Store)}
	return srv, f.Store, ledger
}

func billingUsage(t *testing.T, srv *billingFixture, key string) []payments.UsageEntry {
	t.Helper()
	req := httptest.NewRequest(http.MethodGet, "/v1/payments/usage", nil)
	req.Header.Set("Authorization", "Bearer "+key)
	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("usage status = %d: %s", rec.Code, rec.Body.String())
	}
	var response types.UsageResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	return response.Usage
}

func setupProviderForBillingNoPayoutDestination(t *testing.T, ctx context.Context, ts *httptest.Server, reg *registry.Registry, model string) (*websocket.Conn, string, string) {
	t.Helper()
	pubKey := testkit.PublicKeyB64()
	models := []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}}

	conn := testkit.ConnectProvider(t, ctx, ts.URL, models, pubKey)

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
				resp := testkit.MakeValidChallengeResponse(data, pubKey)
				conn.Write(ctx, websocket.MessageText, resp)

			case protocol.TypeInferenceRequest:
				var inferReq protocol.InferenceRequestMessage
				json.Unmarshal(data, &inferReq)

				testkit.WriteEncryptedChunk(t, ctx, conn, inferReq, pubKey,
					`data: {"id":"chatcmpl-1","choices":[{"delta":{"content":"partial"}}]}`+"\n\n")

				errMsg := protocol.InferenceErrorMessage{
					Type:       protocol.TypeInferenceError,
					RequestID:  inferReq.RequestID,
					Error:      "backend failed after first token",
					StatusCode: statusCode,
					// A mid-stream engine fault; every current provider
					// classifies it with a failure code.
					FailureCode: protocol.FailureCodeGenerationFailure,
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
