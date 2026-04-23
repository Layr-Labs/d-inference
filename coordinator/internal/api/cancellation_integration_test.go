package api

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"encoding/asn1"
	"encoding/base64"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/eigeninference/coordinator/internal/protocol"
	"github.com/eigeninference/coordinator/internal/registry"
	"github.com/eigeninference/coordinator/internal/store"
)

// createTestAttestationJSONWithSerial creates a signed attestation blob with
// a specific serial number. Based on createTestAttestationJSON in provider_test.go,
// but adds serialNumber to the blob for deduplication tests.
func createTestAttestationJSONWithSerial(t *testing.T, serial, encryptionKey string) json.RawMessage {
	t.Helper()

	privKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}

	// Marshal public key as uncompressed point (65 bytes: 0x04 || X || Y)
	xBytes := privKey.PublicKey.X.Bytes()
	yBytes := privKey.PublicKey.Y.Bytes()
	raw := make([]byte, 65)
	raw[0] = 0x04
	copy(raw[1+32-len(xBytes):33], xBytes)
	copy(raw[33+32-len(yBytes):65], yBytes)
	pubKeyB64 := base64.StdEncoding.EncodeToString(raw)

	blobMap := map[string]interface{}{
		"authenticatedRootEnabled": true,
		"chipName":                 "Apple M3 Max",
		"hardwareModel":            "Mac15,8",
		"osVersion":                "15.3.0",
		"publicKey":                pubKeyB64,
		"rdmaDisabled":             true,
		"secureBootEnabled":        true,
		"secureEnclaveAvailable":   true,
		"serialNumber":             serial,
		"sipEnabled":               true,
		"timestamp":                time.Now().UTC().Format(time.RFC3339),
	}
	if encryptionKey != "" {
		blobMap["encryptionPublicKey"] = encryptionKey
		registerTestChallengeSigner(encryptionKey, privKey)
	}

	blobJSON, err := json.Marshal(blobMap)
	if err != nil {
		t.Fatal(err)
	}

	hash := sha256.Sum256(blobJSON)
	r, s, err := ecdsa.Sign(rand.Reader, privKey, hash[:])
	if err != nil {
		t.Fatal(err)
	}
	sigDER, err := asn1.Marshal(ecdsaSigHelper{R: r, S: s})
	if err != nil {
		t.Fatal(err)
	}

	signed := map[string]interface{}{
		"attestation": json.RawMessage(blobJSON),
		"signature":   base64.StdEncoding.EncodeToString(sigDER),
	}

	signedJSON, err := json.Marshal(signed)
	if err != nil {
		t.Fatal(err)
	}

	return signedJSON
}

// connectProviderWithAttestation dials the WebSocket, sends a register message
// with an attestation blob (including serial number), and returns the connection.
func connectProviderWithAttestation(t *testing.T, ctx context.Context, tsURL string, models []protocol.ModelInfo, publicKey string, attestation json.RawMessage) *websocket.Conn {
	t.Helper()
	wsURL := "ws" + strings.TrimPrefix(tsURL, "http") + "/ws/provider"
	conn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatalf("websocket dial: %v", err)
	}
	regMsg := protocol.RegisterMessage{
		Type: protocol.TypeRegister,
		Hardware: protocol.Hardware{
			MachineModel: "Mac15,8",
			ChipName:     "Apple M3 Max",
			MemoryGB:     64,
		},
		Models:                  models,
		Backend:                 "inprocess-mlx",
		PublicKey:               publicKey,
		Attestation:             attestation,
		EncryptedResponseChunks: true,
		PrivacyCapabilities:     testPrivacyCaps(),
	}
	regData, _ := json.Marshal(regMsg)
	if err := conn.Write(ctx, websocket.MessageText, regData); err != nil {
		t.Fatalf("write register: %v", err)
	}
	time.Sleep(200 * time.Millisecond)
	return conn
}

// waitForChallenge reads from the provider WebSocket until an attestation
// challenge arrives, responds to it validly, and returns. Non-challenge
// messages are discarded.
func waitForChallenge(t *testing.T, ctx context.Context, conn *websocket.Conn, pubKey string) {
	t.Helper()
	for {
		_, data, err := conn.Read(ctx)
		if err != nil {
			t.Fatalf("waitForChallenge: read error: %v", err)
		}
		var env struct {
			Type string `json:"type"`
		}
		json.Unmarshal(data, &env)
		if env.Type == protocol.TypeAttestationChallenge {
			resp := makeValidChallengeResponse(data, pubKey)
			if err := conn.Write(ctx, websocket.MessageText, resp); err != nil {
				t.Fatalf("waitForChallenge: write error: %v", err)
			}
			return
		}
	}
}

// setupTestServer creates a test server with a short challenge interval and
// returns the server, registry, store, and httptest server.
func setupTestServer(t *testing.T) (*Server, *registry.Registry, store.Store, *httptest.Server) {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	srv := NewServer(reg, st, logger)
	srv.challengeInterval = 200 * time.Millisecond
	ts := httptest.NewServer(srv.Handler())
	return srv, reg, st, ts
}

// makeProviderRoutable sets trust level to hardware and records a challenge
// success for all currently registered providers so they pass routing checks.
func makeProviderRoutable(reg *registry.Registry) {
	for _, id := range reg.ProviderIDs() {
		reg.SetTrustLevel(id, registry.TrustHardware)
		reg.RecordChallengeSuccess(id)
	}
}

// TestIntegration_RequestCancellationOnConsumerDisconnect verifies that when a
// consumer disconnects mid-stream, the coordinator sends a Cancel message to
// the provider so it stops generating tokens.
func TestIntegration_RequestCancellationOnConsumerDisconnect(t *testing.T) {
	_, reg, _, ts := setupTestServer(t)
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	pubKey := testPublicKeyB64()
	model := "cancel-test-model"
	models := []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}}

	conn := connectProvider(t, ctx, ts.URL, models, pubKey)
	defer conn.Close(websocket.StatusNormalClosure, "")

	// Handle the first attestation challenge so the provider becomes routable.
	challengeCtx, challengeCancel := context.WithTimeout(ctx, 5*time.Second)
	waitForChallenge(t, challengeCtx, conn, pubKey)
	challengeCancel()

	time.Sleep(200 * time.Millisecond)
	makeProviderRoutable(reg)

	// Provider goroutine: reads the inference request, sends one chunk,
	// then waits for the Cancel message from the coordinator.
	type cancelResult struct {
		receivedCancel bool
		cancelMsg      protocol.CancelMessage
		err            error
	}
	resultCh := make(chan cancelResult, 1)

	go func() {
		// Read messages until we get the inference request.
		for {
			_, data, err := conn.Read(ctx)
			if err != nil {
				resultCh <- cancelResult{err: err}
				return
			}
			var env struct {
				Type string `json:"type"`
			}
			json.Unmarshal(data, &env)

			// Handle additional challenges that may arrive.
			if env.Type == protocol.TypeAttestationChallenge {
				resp := makeValidChallengeResponse(data, pubKey)
				conn.Write(ctx, websocket.MessageText, resp)
				continue
			}

			if env.Type == protocol.TypeInferenceRequest {
				var inferReq protocol.InferenceRequestMessage
				json.Unmarshal(data, &inferReq)

				writeEncryptedTestChunk(t, ctx, conn, inferReq, pubKey,
					`data: {"id":"chatcmpl-1","choices":[{"delta":{"content":"Hello"}}]}`+"\n\n")
				break
			}
		}

		// Now wait for the Cancel message (coordinator sends it when consumer disconnects).
		for {
			_, data, err := conn.Read(ctx)
			if err != nil {
				resultCh <- cancelResult{err: err}
				return
			}
			var env struct {
				Type string `json:"type"`
			}
			json.Unmarshal(data, &env)

			// Handle challenges that may arrive while we wait.
			if env.Type == protocol.TypeAttestationChallenge {
				resp := makeValidChallengeResponse(data, pubKey)
				conn.Write(ctx, websocket.MessageText, resp)
				continue
			}

			if env.Type == protocol.TypeCancel {
				var cancelMsg protocol.CancelMessage
				json.Unmarshal(data, &cancelMsg)
				resultCh <- cancelResult{
					receivedCancel: true,
					cancelMsg:      cancelMsg,
				}
				return
			}
		}
	}()

	// Consumer: send a streaming request.
	chatBody := `{"model":"cancel-test-model","messages":[{"role":"user","content":"tell me a story"}],"stream":true}`
	reqCtx, reqCancel := context.WithCancel(ctx)
	httpReq, _ := http.NewRequestWithContext(reqCtx, http.MethodPost, ts.URL+"/v1/chat/completions", strings.NewReader(chatBody))
	httpReq.Header.Set("Authorization", "Bearer test-key")

	resp, err := http.DefaultClient.Do(httpReq)
	if err != nil {
		t.Fatalf("http request: %v", err)
	}

	// Read a small amount to confirm we got the first chunk.
	buf := make([]byte, 4096)
	n, _ := resp.Body.Read(buf)
	firstData := string(buf[:n])
	if !strings.Contains(firstData, "Hello") {
		t.Fatalf("expected first chunk to contain 'Hello', got: %s", firstData)
	}

	// Close the consumer connection by cancelling the request context.
	reqCancel()
	resp.Body.Close()

	// Wait for the provider to receive the cancel message.
	select {
	case result := <-resultCh:
		if result.err != nil {
			t.Fatalf("provider goroutine error: %v", result.err)
		}
		if !result.receivedCancel {
			t.Fatal("provider did not receive a Cancel message")
		}
		if result.cancelMsg.Type != protocol.TypeCancel {
			t.Errorf("cancel message type = %q, want %q", result.cancelMsg.Type, protocol.TypeCancel)
		}
		// The request ID should be non-empty.
		if result.cancelMsg.RequestID == "" {
			t.Error("cancel message request_id is empty")
		}
	case <-time.After(10 * time.Second):
		t.Fatal("timed out waiting for provider to receive Cancel message")
	}
}

// TestIntegration_RequestCancellationCleanup verifies that after a consumer
// disconnects mid-stream, the coordinator cleans up the provider's pending
// requests and returns the provider to an idle/online state.
func TestIntegration_RequestCancellationCleanup(t *testing.T) {
	_, reg, _, ts := setupTestServer(t)
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	pubKey := testPublicKeyB64()
	model := "cancel-cleanup-model"
	models := []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}}

	conn := connectProvider(t, ctx, ts.URL, models, pubKey)
	defer conn.Close(websocket.StatusNormalClosure, "")

	// Handle the first attestation challenge.
	challengeCtx, challengeCancel := context.WithTimeout(ctx, 5*time.Second)
	waitForChallenge(t, challengeCtx, conn, pubKey)
	challengeCancel()

	time.Sleep(200 * time.Millisecond)
	makeProviderRoutable(reg)

	// Capture the provider ID for later checks.
	providerIDs := reg.ProviderIDs()
	if len(providerIDs) == 0 {
		t.Fatal("no providers registered")
	}
	providerID := providerIDs[0]

	// Provider goroutine: receives inference request, sends one chunk,
	// then waits for the cancel. Does NOT send complete.
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
				resp := makeValidChallengeResponse(data, pubKey)
				conn.Write(ctx, websocket.MessageText, resp)
				continue
			}

			if env.Type == protocol.TypeInferenceRequest {
				var inferReq protocol.InferenceRequestMessage
				json.Unmarshal(data, &inferReq)

				writeEncryptedTestChunk(t, ctx, conn, inferReq, pubKey,
					`data: {"id":"chatcmpl-1","choices":[{"delta":{"content":"partial"}}]}`+"\n\n")
				continue
			}

			if env.Type == protocol.TypeCancel {
				// Cancel received, we're done.
				return
			}
		}
	}()

	// Consumer: send a streaming request, read the first chunk, then disconnect.
	chatBody := `{"model":"cancel-cleanup-model","messages":[{"role":"user","content":"hello"}],"stream":true}`
	reqCtx, reqCancel := context.WithCancel(ctx)
	httpReq, _ := http.NewRequestWithContext(reqCtx, http.MethodPost, ts.URL+"/v1/chat/completions", strings.NewReader(chatBody))
	httpReq.Header.Set("Authorization", "Bearer test-key")

	resp, err := http.DefaultClient.Do(httpReq)
	if err != nil {
		t.Fatalf("http request: %v", err)
	}

	// Read a bit to confirm streaming started.
	buf := make([]byte, 4096)
	resp.Body.Read(buf)

	// Cancel the consumer request.
	reqCancel()
	resp.Body.Close()

	// Wait for the provider goroutine to finish (it exits upon receiving cancel).
	select {
	case <-providerDone:
	case <-time.After(10 * time.Second):
		t.Fatal("timed out waiting for provider goroutine to finish")
	}

	// Give the coordinator a moment to process the cleanup.
	time.Sleep(300 * time.Millisecond)

	// Verify cleanup: pending request count should be 0.
	p := reg.GetProvider(providerID)
	if p == nil {
		t.Fatal("provider should still be registered after consumer disconnect")
	}

	pendingCount := p.PendingCount()
	if pendingCount != 0 {
		t.Errorf("provider pending count = %d, want 0", pendingCount)
	}

	// Provider status should go back to online (idle), not stuck in serving.
	p.Mu().Lock()
	status := p.Status
	p.Mu().Unlock()
	if status != registry.StatusOnline {
		t.Errorf("provider status = %v, want %v (online/idle)", status, registry.StatusOnline)
	}
}

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
	pubKeyA := testPublicKeyB64()
	pubKeyB := testPublicKeyB64()

	// --- Provider A: connect with serial ABC123 ---
	attestA := createTestAttestationJSONWithSerial(t, serial, pubKeyA)
	connA := connectProviderWithAttestation(t, ctx, ts.URL, models, pubKeyA, attestA)

	// Wait for attestation verification to process (including dedup check).
	time.Sleep(300 * time.Millisecond)

	// Handle the first challenge for provider A.
	challengeCtx, challengeCancel := context.WithTimeout(ctx, 5*time.Second)
	waitForChallenge(t, challengeCtx, connA, pubKeyA)
	challengeCancel()
	time.Sleep(200 * time.Millisecond)

	// Set trust level for provider A.
	makeProviderRoutable(reg)

	// Verify provider A is routable.
	pA := reg.FindProvider(model)
	if pA == nil {
		t.Fatal("provider A should be routable after registration + challenge")
	}
	providerAID := pA.ID

	// Verify exactly 1 provider.
	if count := reg.ProviderCount(); count != 1 {
		t.Fatalf("provider count = %d, want 1 after provider A registration", count)
	}

	// --- Provider B: connect with the SAME serial ABC123 ---
	attestB := createTestAttestationJSONWithSerial(t, serial, pubKeyB)
	connB := connectProviderWithAttestation(t, ctx, ts.URL, models, pubKeyB, attestB)
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
	waitForChallenge(t, challengeCtx2, connB, pubKeyB)
	challengeCancel2()
	time.Sleep(200 * time.Millisecond)

	makeProviderRoutable(reg)

	// Verify provider B is routable.
	pB := reg.FindProvider(model)
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
	pubKeyA := testPublicKeyB64()
	pubKeyB := testPublicKeyB64()

	// --- Provider A: connect with serial ---
	attestA := createTestAttestationJSONWithSerial(t, serial, pubKeyA)
	connA := connectProviderWithAttestation(t, ctx, ts.URL, models, pubKeyA, attestA)

	time.Sleep(300 * time.Millisecond)

	// Handle challenge for A.
	challengeCtxA, challengeCancelA := context.WithTimeout(ctx, 5*time.Second)
	waitForChallenge(t, challengeCtxA, connA, pubKeyA)
	challengeCancelA()
	time.Sleep(200 * time.Millisecond)
	makeProviderRoutable(reg)

	// --- Provider B: connect with same serial, replacing A ---
	attestB := createTestAttestationJSONWithSerial(t, serial, pubKeyB)
	connB := connectProviderWithAttestation(t, ctx, ts.URL, models, pubKeyB, attestB)
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
	waitForChallenge(t, challengeCtxB, connB, pubKeyB)
	challengeCancelB()
	time.Sleep(200 * time.Millisecond)
	makeProviderRoutable(reg)

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
				resp := makeValidChallengeResponse(data, pubKeyB)
				connB.Write(ctx, websocket.MessageText, resp)
				continue
			}

			if env.Type == protocol.TypeInferenceRequest {
				var inferReq protocol.InferenceRequestMessage
				json.Unmarshal(data, &inferReq)

				mu.Lock()
				providerBReceivedRequest = true
				mu.Unlock()

				writeEncryptedTestChunk(t, ctx, connB, inferReq, pubKeyB,
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
