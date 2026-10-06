package provider_test

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	testkit "github.com/eigeninference/d-inference/coordinator/tests/internal/testkit"
	"nhooyr.io/websocket"
)

// TestIntegration_ProviderDeduplicationBySerial verifies that when a second
// provider connects with the same serial number as an existing provider,
// the first provider's connection is closed and only the new provider remains.
func TestIntegration_ProviderDeduplicationBySerial(t *testing.T) {
	_, reg, _, ts := setupTestServer(t)
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	serial := "ABC123"
	model := "dedup-model"
	models := []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}}
	pubKeyA := testkit.PublicKeyB64()
	pubKeyB := testkit.PublicKeyB64()

	// --- Provider A: connect with serial ABC123 ---
	attestA := testkit.CreateAttestationJSONWithSerial(t, serial, pubKeyA)
	connA := testkit.ConnectProviderWithAttestation(t, ctx, ts.URL, models, pubKeyA, attestA)

	// Wait for attestation verification to process (including dedup check).
	time.Sleep(300 * time.Millisecond)

	// Handle the first challenge for provider A.
	challengeCtx, challengeCancel := context.WithTimeout(ctx, 5*time.Second)
	testkit.WaitForChallenge(t, challengeCtx, connA, pubKeyA)
	challengeCancel()
	time.Sleep(200 * time.Millisecond)
	testkit.MakeProviderRoutable( // Set trust level for provider A.
		reg)

	// Verify provider A is routable.
	pA := testkit.FindRoutableProvider(reg, model)
	if pA == nil {
		t.Fatal("provider A should be routable after registration + challenge")
	}
	providerAID := pA.ID

	// Verify exactly 1 provider.
	if count := reg.ProviderCount(); count != 1 {
		t.Fatalf("provider count = %d, want 1 after provider A registration", count)
	}

	// --- Provider B: connect with the SAME serial ABC123 ---
	attestB := testkit.CreateAttestationJSONWithSerial(t, serial, pubKeyB)
	connB := testkit.ConnectProviderWithAttestation(t, ctx, ts.URL, models, pubKeyB, attestB)
	defer connB.Close(websocket.StatusNormalClosure, "")

	// Wait for attestation verification and deduplication to complete.
	time.Sleep(500 * time.Millisecond)

	// Verify provider A was evicted (only 1 provider should remain).
	if count := reg.ProviderCount(); count != 1 {
		t.Fatalf("provider count = %d, want 1 after deduplication", count)
	}

	// The remaining provider should be provider B (not A).
	pOld := reg.GetProvider(providerAID)
	if pOld != nil {
		t.Error("provider A should have been evicted from registry")
	}

	// Provider A's WebSocket should be closed. Keep reading until we get an
	// error (there may be pending challenge messages in the buffer before the
	// close frame arrives).
	readCtx, readCancel := context.WithTimeout(ctx, 5*time.Second)
	defer readCancel()
	connAClosed := false
	for {
		_, _, readErr := connA.Read(readCtx)
		if readErr != nil {
			connAClosed = true
			break
		}
	}
	if !connAClosed {
		t.Error("provider A's WebSocket should be closed after deduplication")
	}

	// Handle the challenge for provider B so it becomes routable.
	challengeCtx2, challengeCancel2 := context.WithTimeout(ctx, 5*time.Second)
	testkit.WaitForChallenge(t, challengeCtx2, connB, pubKeyB)
	challengeCancel2()
	time.Sleep(200 * time.Millisecond)
	testkit.MakeProviderRoutable(reg)

	// Verify provider B is routable.
	pB := testkit.FindRoutableProvider(reg, model)
	if pB == nil {
		t.Fatal("provider B should be routable after deduplication + challenge")
	}
}

// TestIntegration_ProviderDeduplicationPreservesNewest verifies that after
// provider B replaces provider A (same serial), inference requests go to
// provider B and provider A's WebSocket is closed.
func TestIntegration_ProviderDeduplicationPreservesNewest(t *testing.T) {
	_, reg, _, ts := setupTestServer(t)
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	serial := "DEDUP-NEWEST-001"
	model := "dedup-newest-model"
	models := []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}}
	pubKeyA := testkit.PublicKeyB64()
	pubKeyB := testkit.PublicKeyB64()

	// --- Provider A: connect with serial ---
	attestA := testkit.CreateAttestationJSONWithSerial(t, serial, pubKeyA)
	connA := testkit.ConnectProviderWithAttestation(t, ctx, ts.URL, models, pubKeyA, attestA)

	time.Sleep(300 * time.Millisecond)

	// Handle challenge for A.
	challengeCtxA, challengeCancelA := context.WithTimeout(ctx, 5*time.Second)
	testkit.WaitForChallenge(t, challengeCtxA, connA, pubKeyA)
	challengeCancelA()
	time.Sleep(200 * time.Millisecond)
	testkit.MakeProviderRoutable(reg)

	// --- Provider B: connect with same serial, replacing A ---
	attestB := testkit.CreateAttestationJSONWithSerial(t, serial, pubKeyB)
	connB := testkit.ConnectProviderWithAttestation(t, ctx, ts.URL, models, pubKeyB, attestB)
	defer connB.Close(websocket.StatusNormalClosure, "")

	// Wait for deduplication.
	time.Sleep(500 * time.Millisecond)

	// Verify A was evicted.
	if count := reg.ProviderCount(); count != 1 {
		t.Fatalf("provider count = %d, want 1 after dedup", count)
	}

	// Verify A's WebSocket is actually closed. Drain any buffered messages
	// until we get a read error.
	readCtx, readCancel := context.WithTimeout(ctx, 5*time.Second)
	defer readCancel()
	connAClosed := false
	for {
		_, _, readErr := connA.Read(readCtx)
		if readErr != nil {
			connAClosed = true
			break
		}
	}
	if !connAClosed {
		t.Error("provider A's WebSocket should be closed after being replaced")
	}

	// Handle challenge for B so it becomes routable.
	challengeCtxB, challengeCancelB := context.WithTimeout(ctx, 5*time.Second)
	testkit.WaitForChallenge(t, challengeCtxB, connB, pubKeyB)
	challengeCancelB()
	time.Sleep(200 * time.Millisecond)
	testkit.MakeProviderRoutable(reg)

	// Provider B should be the one serving requests. Send a request and
	// verify provider B receives and serves it.
	providerBDone := make(chan struct{})
	var providerBReceivedRequest bool
	var mu sync.Mutex

	go func() {
		defer close(providerBDone)
		for {
			_, data, err := connB.Read(ctx)
			if err != nil {
				return
			}
			var env struct {
				Type string `json:"type"`
			}
			json.Unmarshal(data, &env)

			if env.Type == protocol.TypeAttestationChallenge {
				resp := testkit.MakeValidChallengeResponse(data, pubKeyB)
				connB.Write(ctx, websocket.MessageText, resp)
				continue
			}

			if env.Type == protocol.TypeInferenceRequest {
				var inferReq protocol.InferenceRequestMessage
				json.Unmarshal(data, &inferReq)

				mu.Lock()
				providerBReceivedRequest = true
				mu.Unlock()
				testkit.WriteEncryptedChunk(t, ctx, connB, inferReq, pubKeyB,
					`data: {"id":"chatcmpl-1","choices":[{"delta":{"content":"from-B"}}]}`+"\n\n")

				complete := protocol.InferenceCompleteMessage{
					Type:      protocol.TypeInferenceComplete,
					RequestID: inferReq.RequestID,
					Usage:     protocol.UsageInfo{PromptTokens: 5, CompletionTokens: 1},
				}
				completeData, _ := json.Marshal(complete)
				connB.Write(ctx, websocket.MessageText, completeData)
				return
			}
		}
	}()

	// Send a consumer request.
	chatBody := `{"model":"dedup-newest-model","messages":[{"role":"user","content":"hello"}],"stream":true}`
	httpReq, _ := http.NewRequestWithContext(ctx, http.MethodPost, ts.URL+"/v1/chat/completions", strings.NewReader(chatBody))
	httpReq.Header.Set("Authorization", "Bearer test-key")

	resp, err := http.DefaultClient.Do(httpReq)
	if err != nil {
		t.Fatalf("http request: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(resp.Body)
		t.Fatalf("status = %d, body = %s", resp.StatusCode, body)
	}

	// Read the response body.
	body, _ := io.ReadAll(resp.Body)
	responseStr := string(body)

	if !strings.Contains(responseStr, "from-B") {
		t.Errorf("response should contain 'from-B' (served by provider B), got: %s", responseStr)
	}

	// Wait for provider B goroutine to finish.
	select {
	case <-providerBDone:
	case <-time.After(10 * time.Second):
		t.Fatal("timed out waiting for provider B goroutine")
	}

	mu.Lock()
	gotRequest := providerBReceivedRequest
	mu.Unlock()

	if !gotRequest {
		t.Error("provider B should have received the inference request")
	}
}
