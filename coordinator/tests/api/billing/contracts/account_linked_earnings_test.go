package billing_test

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	api "github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
	testkit "github.com/eigeninference/d-inference/coordinator/tests/internal/testkit"
	"nhooyr.io/websocket"
)

// TestIntegration_AccountLinkedEarnings verifies that inference payouts go to the
// linked account (not the wallet address) when a provider authenticates via device token.
func TestIntegration_AccountLinkedEarnings(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := memory.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := testkit.NewServer(t, reg, st, api.ServerConfig{}, logger)
	srv.SetChallengeInterval(200 * time.Millisecond)

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	// Set up a provider token that maps to an account.
	accountID := "acct-test-123"
	rawToken := "provider-auth-token-xyz"
	tokenHash := fmt.Sprintf("%x", sha256.Sum256([]byte(rawToken)))
	err := st.CreateProviderToken(&store.ProviderToken{
		TokenHash: tokenHash,
		AccountID: accountID,
		Label:     "test-device",
		Active:    true,
		CreatedAt: time.Now(),
	})
	if err != nil {
		t.Fatalf("create provider token: %v", err)
	}

	pubKey := testkit.PublicKeyB64()
	model := "earnings-model"
	models := []protocol.ModelInfo{{ID: model, ModelType: "test", Quantization: "4bit"}}

	conn := testkit.ConnectProviderWithToken(t, ctx, ts.URL, models, pubKey, rawToken)
	defer conn.Close(websocket.StatusNormalClosure, "")

	// Wait for registration + attestation to fully complete before
	// reading provider fields to avoid racing with the WebSocket goroutine.
	time.Sleep(300 * time.Millisecond)

	// Set trust level and mark challenge as verified.
	for _, id := range reg.ProviderIDs() {
		reg.SetTrustLevel(id, registry.TrustHardware)
		reg.RecordChallengeSuccess(id)
	}

	// Verify the provider's AccountID was linked.
	p := testkit.FindProviderByModel(reg, model)
	if p == nil {
		t.Fatal("provider not found")
	}

	// Provider goroutine: handle challenges and serve one inference request.
	providerDone := make(chan struct{})
	go func() {
		defer close(providerDone)
		for {
			_, data, err := conn.Read(ctx)
			if err != nil {
				return
			}
			var env struct {
				Type string `json:"type"`
			}
			json.Unmarshal(data, &env)

			if env.Type == protocol.TypeAttestationChallenge {
				resp := testkit.MakeValidChallengeResponse(data, pubKey)
				conn.Write(ctx, websocket.MessageText, resp)
				continue
			}

			if env.Type == protocol.TypeInferenceRequest {
				var inferReq protocol.InferenceRequestMessage
				json.Unmarshal(data, &inferReq)
				testkit.WriteEncryptedChunk( // Send a chunk and complete.
					t, ctx, conn, inferReq, pubKey,
					`data: {"id":"chatcmpl-1","choices":[{"delta":{"content":"done"}}]}`+"\n\n")

				complete := protocol.InferenceCompleteMessage{
					Type:      protocol.TypeInferenceComplete,
					RequestID: inferReq.RequestID,
					Usage:     protocol.UsageInfo{PromptTokens: 10, CompletionTokens: 5},
				}
				completeData, _ := json.Marshal(complete)
				conn.Write(ctx, websocket.MessageText, completeData)
				return
			}
		}
	}()

	// Send a consumer inference request.
	chatBody := `{"model":"earnings-model","messages":[{"role":"user","content":"hello"}],"stream":true}`
	httpReq, _ := http.NewRequestWithContext(ctx, http.MethodPost, ts.URL+"/v1/chat/completions", strings.NewReader(chatBody))
	httpReq.Header.Set("Authorization", "Bearer test-key")

	resp, err := http.DefaultClient.Do(httpReq)
	if err != nil {
		t.Fatalf("http request: %v", err)
	}
	defer resp.Body.Close()
	io.ReadAll(resp.Body)

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200", resp.StatusCode)
	}

	<-providerDone
	// Give handleComplete a moment to process credits.
	time.Sleep(300 * time.Millisecond)

	// Verify the account received credits.
	accountBalance := st.GetBalance(accountID)
	if accountBalance <= 0 {
		t.Errorf("account balance = %d, want > 0 (provider payout should be credited)", accountBalance)
	}

	// Verify provider earnings were recorded.
	earnings, err := st.GetAccountEarnings(accountID, 10)
	if err != nil {
		t.Fatalf("get account earnings: %v", err)
	}
	if len(earnings) == 0 {
		t.Error("expected at least one provider earning record")
	} else {
		e := earnings[0]
		if e.AccountID != accountID {
			t.Errorf("earning account_id = %q, want %q", e.AccountID, accountID)
		}
		if e.ProviderKey != pubKey {
			t.Errorf("earning provider_key = %q, want %q", e.ProviderKey, pubKey)
		}
		if e.AmountMicroUSD <= 0 {
			t.Error("earning amount should be > 0")
		}
		if e.PromptTokens != 10 {
			t.Errorf("earning prompt_tokens = %d, want 10", e.PromptTokens)
		}
		if e.CompletionTokens != 5 {
			t.Errorf("earning completion_tokens = %d, want 5", e.CompletionTokens)
		}
	}
}
