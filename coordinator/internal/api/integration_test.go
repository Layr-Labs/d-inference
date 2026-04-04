package api

import (
	"context"
	crand "crypto/rand"
	"crypto/sha256"
	"encoding/base64"
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

	"github.com/dginf/coordinator/internal/e2e"
	"github.com/dginf/coordinator/internal/protocol"
	"github.com/dginf/coordinator/internal/registry"
	"github.com/dginf/coordinator/internal/store"
	"golang.org/x/crypto/nacl/box"
	"nhooyr.io/websocket"
)

// handleProviderMessages reads WebSocket messages in a loop, dispatches
// challenges vs inference requests, and sends responses. It exits when
// the context is cancelled or the connection closes.
func handleProviderMessages(ctx context.Context, t *testing.T, conn *websocket.Conn, handler func(msgType string, data []byte) []byte) {
	t.Helper()
	for {
		_, data, err := conn.Read(ctx)
		if err != nil {
			return
		}
		var envelope struct {
			Type string `json:"type"`
		}
		if err := json.Unmarshal(data, &envelope); err != nil {
			continue
		}
		resp := handler(envelope.Type, data)
		if resp != nil {
			if err := conn.Write(ctx, websocket.MessageText, resp); err != nil {
				return
			}
		}
	}
}

// makeValidChallengeResponse creates a valid attestation response for a challenge.
// "Valid" here means: echoed nonce, matching public key, non-empty signature,
// and all security posture fields set to safe values.
func makeValidChallengeResponse(data []byte, publicKey string) []byte {
	var challenge protocol.AttestationChallengeMessage
	json.Unmarshal(data, &challenge)
	rdmaDisabled := true
	sipEnabled := true
	secureBootEnabled := true
	resp := protocol.AttestationResponseMessage{
		Type:              protocol.TypeAttestationResponse,
		Nonce:             challenge.Nonce,
		Signature:         "dGVzdHNpZ25hdHVyZQ==",
		PublicKey:         publicKey,
		RDMADisabled:      &rdmaDisabled,
		SIPEnabled:        &sipEnabled,
		SecureBootEnabled: &secureBootEnabled,
	}
	respData, _ := json.Marshal(resp)
	return respData
}

// makeInvalidChallengeResponse creates a response with the correct nonce
// but a wrong public key. This ensures the response reaches the challenge
// tracker (nonce must match for dispatch) but verification fails.
func makeInvalidChallengeResponse(data []byte) []byte {
	var challenge protocol.AttestationChallengeMessage
	json.Unmarshal(data, &challenge)
	rdmaDisabled := true
	sipEnabled := true
	secureBootEnabled := true
	resp := protocol.AttestationResponseMessage{
		Type:              protocol.TypeAttestationResponse,
		Nonce:             challenge.Nonce, // correct nonce so tracker dispatches it
		Signature:         "c2lnbmF0dXJl",
		PublicKey:         "d3Jvbmdfa2V5X21pc21hdGNo", // wrong key, causes verification failure
		RDMADisabled:      &rdmaDisabled,
		SIPEnabled:        &sipEnabled,
		SecureBootEnabled: &secureBootEnabled,
	}
	respData, _ := json.Marshal(resp)
	return respData
}

// connectProvider dials the WebSocket, sends a register message, and returns
// the connection. It waits briefly for registration to be processed.
func connectProvider(t *testing.T, ctx context.Context, tsURL string, models []protocol.ModelInfo, publicKey string) *websocket.Conn {
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
		Models:    models,
		Backend:   "test",
		PublicKey: publicKey,
	}
	regData, _ := json.Marshal(regMsg)
	if err := conn.Write(ctx, websocket.MessageText, regData); err != nil {
		t.Fatalf("write register: %v", err)
	}
	time.Sleep(150 * time.Millisecond)
	return conn
}

// connectProviderWithToken dials the WebSocket with an auth token.
func connectProviderWithToken(t *testing.T, ctx context.Context, tsURL string, models []protocol.ModelInfo, publicKey, authToken, walletAddress string) *websocket.Conn {
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
		Models:        models,
		Backend:       "test",
		PublicKey:     publicKey,
		AuthToken:     authToken,
		WalletAddress: walletAddress,
	}
	regData, _ := json.Marshal(regMsg)
	if err := conn.Write(ctx, websocket.MessageText, regData); err != nil {
		t.Fatalf("write register: %v", err)
	}
	time.Sleep(150 * time.Millisecond)
	return conn
}

// TestIntegration_ProviderReconnectRequiresChallenge verifies that a provider
// that disconnects and reconnects is NOT routable until it passes a new challenge.
func TestIntegration_ProviderReconnectRequiresChallenge(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	srv := NewServer(reg, st, logger)
	srv.challengeInterval = 100 * time.Millisecond

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	pubKey := testPublicKeyB64()
	model := "reconnect-model"
	models := []protocol.ModelInfo{{ID: model, ModelType: "test", Quantization: "4bit"}}

	// --- Phase 1: Connect, handle challenge, verify routable ---
	conn1 := connectProvider(t, ctx, ts.URL, models, pubKey)

	// Handle the first challenge (arrives after ~100ms).
	challengeHandled := make(chan struct{})
	go func() {
		defer close(challengeHandled)
		for {
			_, data, err := conn1.Read(ctx)
			if err != nil {
				return
			}
			var env struct {
				Type string `json:"type"`
			}
			json.Unmarshal(data, &env)
			if env.Type == protocol.TypeAttestationChallenge {
				resp := makeValidChallengeResponse(data, pubKey)
				conn1.Write(ctx, websocket.MessageText, resp)
				return
			}
		}
	}()

	select {
	case <-challengeHandled:
	case <-time.After(3 * time.Second):
		t.Fatal("timed out waiting for first challenge")
	}

	// Wait for verification to complete.
	time.Sleep(200 * time.Millisecond)

	// Set trust level (challenges verify liveness, but trust level is set
	// separately — simulating attestation verification).
	for _, id := range reg.ProviderIDs() {
		reg.SetTrustLevel(id, registry.TrustHardware)
	}

	// Provider should be routable now.
	p := reg.FindProvider(model)
	if p == nil {
		t.Fatal("provider should be routable after passing challenge")
	}

	// --- Phase 2: Disconnect ---
	conn1.Close(websocket.StatusNormalClosure, "done")
	time.Sleep(300 * time.Millisecond)

	if reg.ProviderCount() != 0 {
		t.Fatalf("provider count after disconnect = %d, want 0", reg.ProviderCount())
	}

	// --- Phase 3: Reconnect with a new connection ---
	conn2 := connectProvider(t, ctx, ts.URL, models, pubKey)
	defer conn2.Close(websocket.StatusNormalClosure, "")

	// Set trust level on the new provider.
	for _, id := range reg.ProviderIDs() {
		reg.SetTrustLevel(id, registry.TrustHardware)
	}

	// Before handling the challenge, the provider should NOT be routable
	// because LastChallengeVerified is zero.
	p2 := reg.FindProvider(model)
	if p2 != nil {
		t.Fatal("provider should NOT be routable before passing challenge after reconnect")
	}

	// Handle the new challenge.
	challengeHandled2 := make(chan struct{})
	go func() {
		defer close(challengeHandled2)
		for {
			_, data, err := conn2.Read(ctx)
			if err != nil {
				return
			}
			var env struct {
				Type string `json:"type"`
			}
			json.Unmarshal(data, &env)
			if env.Type == protocol.TypeAttestationChallenge {
				resp := makeValidChallengeResponse(data, pubKey)
				conn2.Write(ctx, websocket.MessageText, resp)
				return
			}
		}
	}()

	select {
	case <-challengeHandled2:
	case <-time.After(3 * time.Second):
		t.Fatal("timed out waiting for second challenge")
	}

	time.Sleep(200 * time.Millisecond)

	// Now provider should be routable again.
	p3 := reg.FindProvider(model)
	if p3 == nil {
		t.Fatal("provider should be routable after passing challenge on reconnect")
	}
}

// TestIntegration_ChallengeFailureBlocksRouting verifies that a provider
// responding with wrong nonces gets marked untrusted after MaxFailedChallenges.
func TestIntegration_ChallengeFailureBlocksRouting(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	srv := NewServer(reg, st, logger)
	srv.challengeInterval = 200 * time.Millisecond

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	pubKey := testPublicKeyB64()
	model := "fail-challenge-model"
	models := []protocol.ModelInfo{{ID: model, ModelType: "test", Quantization: "4bit"}}

	conn := connectProvider(t, ctx, ts.URL, models, pubKey)
	defer conn.Close(websocket.StatusNormalClosure, "")

	// Handle first challenge correctly so the provider becomes routable.
	firstHandled := make(chan struct{})
	go func() {
		defer close(firstHandled)
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
				return
			}
		}
	}()

	select {
	case <-firstHandled:
	case <-time.After(3 * time.Second):
		t.Fatal("timed out waiting for first challenge")
	}

	time.Sleep(200 * time.Millisecond)

	// Set trust level.
	for _, id := range reg.ProviderIDs() {
		reg.SetTrustLevel(id, registry.TrustHardware)
	}

	// Verify routable after first challenge.
	if p := reg.FindProvider(model); p == nil {
		t.Fatal("provider should be routable after first challenge")
	}

	// Now respond to the next MaxFailedChallenges challenges with wrong nonces.
	failCount := 0
	failsDone := make(chan struct{})
	go func() {
		defer close(failsDone)
		for failCount < MaxFailedChallenges {
			_, data, err := conn.Read(ctx)
			if err != nil {
				return
			}
			var env struct {
				Type string `json:"type"`
			}
			json.Unmarshal(data, &env)
			if env.Type == protocol.TypeAttestationChallenge {
				resp := makeInvalidChallengeResponse(data)
				conn.Write(ctx, websocket.MessageText, resp)
				failCount++
			}
		}
	}()

	select {
	case <-failsDone:
	case <-time.After(10 * time.Second):
		t.Fatalf("timed out waiting for %d failed challenges, got %d", MaxFailedChallenges, failCount)
	}

	// Wait for the last failure to be processed.
	time.Sleep(500 * time.Millisecond)

	// Provider should be untrusted and NOT routable.
	p := findProviderByModel(reg, model)
	if p != nil {
		p.Mu().Lock()
		status := p.Status
		p.Mu().Unlock()
		if status != registry.StatusUntrusted {
			t.Errorf("provider status = %v, want untrusted", status)
		}
	}
	if found := reg.FindProvider(model); found != nil {
		t.Error("untrusted provider should not be routable")
	}
}

// TestIntegration_E2EEncryptionRoundtrip tests that the coordinator's
// encryption can be decrypted by Go code using the same NaCl Box primitives
// that the Rust provider uses.
func TestIntegration_E2EEncryptionRoundtrip(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	srv := NewServer(reg, st, logger)
	srv.challengeInterval = 200 * time.Millisecond

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	// Generate a real X25519 keypair (simulating the provider's Secure Enclave key).
	providerPub, providerPriv, err := box.GenerateKey(crand.Reader)
	if err != nil {
		t.Fatalf("generate keypair: %v", err)
	}
	pubKeyB64 := base64.StdEncoding.EncodeToString(providerPub[:])

	model := "e2e-model"
	models := []protocol.ModelInfo{{ID: model, ModelType: "test", Quantization: "4bit"}}

	conn := connectProvider(t, ctx, ts.URL, models, pubKeyB64)
	defer conn.Close(websocket.StatusNormalClosure, "")

	// Handle the first challenge so the provider is routable.
	for _, id := range reg.ProviderIDs() {
		reg.SetTrustLevel(id, registry.TrustHardware)
		reg.RecordChallengeSuccess(id)
	}

	// Start a goroutine to handle challenges and capture the inference request.
	type inferResult struct {
		decryptedBody []byte
		err           error
	}
	resultCh := make(chan inferResult, 1)

	go func() {
		for {
			_, data, err := conn.Read(ctx)
			if err != nil {
				resultCh <- inferResult{err: err}
				return
			}
			var env struct {
				Type string `json:"type"`
			}
			json.Unmarshal(data, &env)

			if env.Type == protocol.TypeAttestationChallenge {
				resp := makeValidChallengeResponse(data, pubKeyB64)
				conn.Write(ctx, websocket.MessageText, resp)
				continue
			}

			if env.Type == protocol.TypeInferenceRequest {
				// Parse the encrypted body.
				var inferReq struct {
					Type          string `json:"type"`
					RequestID     string `json:"request_id"`
					EncryptedBody *struct {
						EphemeralPublicKey string `json:"ephemeral_public_key"`
						Ciphertext         string `json:"ciphertext"`
					} `json:"encrypted_body"`
				}
				if err := json.Unmarshal(data, &inferReq); err != nil {
					resultCh <- inferResult{err: err}
					return
				}

				if inferReq.EncryptedBody == nil {
					resultCh <- inferResult{err: err}
					return
				}

				// Decrypt using the provider's private key and the e2e package.
				payload := &e2e.EncryptedPayload{
					EphemeralPublicKey: inferReq.EncryptedBody.EphemeralPublicKey,
					Ciphertext:         inferReq.EncryptedBody.Ciphertext,
				}
				decrypted, err := e2e.DecryptWithPrivateKey(payload, *providerPriv)
				resultCh <- inferResult{decryptedBody: decrypted, err: err}

				// Send back chunks + complete so the consumer handler doesn't hang.
				chunk := protocol.InferenceResponseChunkMessage{
					Type:      protocol.TypeInferenceResponseChunk,
					RequestID: inferReq.RequestID,
					Data:      `data: {"id":"chatcmpl-1","choices":[{"delta":{"content":"ok"}}]}` + "\n\n",
				}
				chunkData, _ := json.Marshal(chunk)
				conn.Write(ctx, websocket.MessageText, chunkData)

				complete := protocol.InferenceCompleteMessage{
					Type:      protocol.TypeInferenceComplete,
					RequestID: inferReq.RequestID,
					Usage:     protocol.UsageInfo{PromptTokens: 5, CompletionTokens: 1},
				}
				completeData, _ := json.Marshal(complete)
				conn.Write(ctx, websocket.MessageText, completeData)
				return
			}
		}
	}()

	// Send a consumer request.
	chatBody := `{"model":"e2e-model","messages":[{"role":"user","content":"what is 2+2?"}],"stream":true}`
	httpReq, _ := http.NewRequestWithContext(ctx, http.MethodPost, ts.URL+"/v1/chat/completions", strings.NewReader(chatBody))
	httpReq.Header.Set("Authorization", "Bearer test-key")

	resp, err := http.DefaultClient.Do(httpReq)
	if err != nil {
		t.Fatalf("http request: %v", err)
	}
	defer resp.Body.Close()
	// Drain the body to let the provider complete.
	io.ReadAll(resp.Body)

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200", resp.StatusCode)
	}

	// Get the decryption result from the provider goroutine.
	select {
	case result := <-resultCh:
		if result.err != nil {
			t.Fatalf("provider decryption failed: %v", result.err)
		}

		// The decrypted body should be a valid InferenceRequestBody.
		var body protocol.InferenceRequestBody
		if err := json.Unmarshal(result.decryptedBody, &body); err != nil {
			t.Fatalf("unmarshal decrypted body: %v", err)
		}

		if body.Model != "e2e-model" {
			t.Errorf("decrypted model = %q, want %q", body.Model, "e2e-model")
		}
		if len(body.Messages) != 1 {
			t.Fatalf("decrypted messages count = %d, want 1", len(body.Messages))
		}
		if body.Messages[0].Content != "what is 2+2?" {
			t.Errorf("decrypted content = %q, want %q", body.Messages[0].Content, "what is 2+2?")
		}
		if body.Messages[0].Role != "user" {
			t.Errorf("decrypted role = %q, want %q", body.Messages[0].Role, "user")
		}
		if !body.Stream {
			t.Error("decrypted stream = false, want true")
		}
	case <-time.After(5 * time.Second):
		t.Fatal("timed out waiting for provider decryption result")
	}
}

// TestIntegration_AccountLinkedEarnings verifies that inference payouts go to the
// linked account (not the wallet address) when a provider authenticates via device token.
func TestIntegration_AccountLinkedEarnings(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	srv := NewServer(reg, st, logger)
	srv.challengeInterval = 200 * time.Millisecond

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	// Set up a provider token that maps to an account.
	accountID := "acct-test-123"
	rawToken := "provider-auth-token-xyz"
	tokenHash := sha256Hex(rawToken)
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

	pubKey := testPublicKeyB64()
	model := "earnings-model"
	models := []protocol.ModelInfo{{ID: model, ModelType: "test", Quantization: "4bit"}}
	walletAddr := "0xProviderWalletShouldNotBeUsed"

	conn := connectProviderWithToken(t, ctx, ts.URL, models, pubKey, rawToken, walletAddr)
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
	p := findProviderByModel(reg, model)
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
				resp := makeValidChallengeResponse(data, pubKey)
				conn.Write(ctx, websocket.MessageText, resp)
				continue
			}

			if env.Type == protocol.TypeInferenceRequest {
				var inferReq protocol.InferenceRequestMessage
				json.Unmarshal(data, &inferReq)

				// Send a chunk and complete.
				chunk := protocol.InferenceResponseChunkMessage{
					Type:      protocol.TypeInferenceResponseChunk,
					RequestID: inferReq.RequestID,
					Data:      `data: {"id":"chatcmpl-1","choices":[{"delta":{"content":"done"}}]}` + "\n\n",
				}
				chunkData, _ := json.Marshal(chunk)
				conn.Write(ctx, websocket.MessageText, chunkData)

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

	// Verify the account received credits, not the wallet address.
	accountBalance := st.GetBalance(accountID)
	if accountBalance <= 0 {
		t.Errorf("account balance = %d, want > 0 (provider payout should be credited)", accountBalance)
	}

	walletBalance := st.GetBalance(walletAddr)
	if walletBalance != 0 {
		t.Errorf("wallet balance = %d, want 0 (account-linked provider should not credit wallet)", walletBalance)
	}

	// Verify provider earnings were recorded.
	earnings, err := st.GetProviderEarnings(pubKey, 10)
	if err != nil {
		t.Fatalf("get provider earnings: %v", err)
	}
	if len(earnings) == 0 {
		t.Error("expected at least one provider earning record")
	} else {
		e := earnings[0]
		if e.AccountID != accountID {
			t.Errorf("earning account_id = %q, want %q", e.AccountID, accountID)
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

// TestIntegration_RequestQueueDrain verifies that queued requests are assigned
// to a provider when it becomes idle.
func TestIntegration_RequestQueueDrain(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	srv := NewServer(reg, st, logger)
	srv.challengeInterval = 200 * time.Millisecond

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	pubKey := testPublicKeyB64()
	model := "queue-model"
	models := []protocol.ModelInfo{{ID: model, ModelType: "test", Quantization: "4bit"}}

	conn := connectProvider(t, ctx, ts.URL, models, pubKey)
	defer conn.Close(websocket.StatusNormalClosure, "")

	// Set trust level and mark challenge as verified.
	for _, id := range reg.ProviderIDs() {
		reg.SetTrustLevel(id, registry.TrustHardware)
		reg.RecordChallengeSuccess(id)
	}

	providerID := reg.ProviderIDs()[0]
	p := reg.GetProvider(providerID)

	// Fill the provider to max concurrency with dummy pending requests.
	for i := 0; i < registry.MaxConcurrentRequests; i++ {
		pr := &registry.PendingRequest{
			RequestID:  "dummy-" + string(rune('a'+i)),
			ProviderID: providerID,
			Model:      model,
			ChunkCh:    make(chan string, 1),
			CompleteCh: make(chan protocol.UsageInfo, 1),
			ErrorCh:    make(chan protocol.InferenceErrorMessage, 1),
		}
		p.AddPending(pr)
	}

	// Verify provider is at max concurrency and not available.
	if found := reg.FindProvider(model); found != nil {
		t.Fatal("provider at max concurrency should not be routable")
	}

	// Enqueue a request into the queue.
	queuedReq := &registry.QueuedRequest{
		RequestID:  "queued-req-1",
		Model:      model,
		ResponseCh: make(chan *registry.Provider, 1),
	}
	if err := reg.Queue().Enqueue(queuedReq); err != nil {
		t.Fatalf("enqueue: %v", err)
	}

	if reg.Queue().QueueSize(model) != 1 {
		t.Fatalf("queue size = %d, want 1", reg.Queue().QueueSize(model))
	}

	// Simulate one request completing: remove a pending request.
	p.RemovePending("dummy-a")

	// Call SetProviderIdle which should drain the queue.
	reg.SetProviderIdle(providerID)

	// The queued request should receive a provider within a short time.
	select {
	case assigned := <-queuedReq.ResponseCh:
		if assigned == nil {
			t.Fatal("queued request received nil provider")
		}
		if assigned.ID != providerID {
			t.Errorf("assigned provider = %q, want %q", assigned.ID, providerID)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("queued request was not assigned a provider")
	}

	// Queue should now be empty.
	if reg.Queue().QueueSize(model) != 0 {
		t.Errorf("queue size after drain = %d, want 0", reg.Queue().QueueSize(model))
	}
}

// sha256Hex computes SHA-256 of a string and returns hex encoding.
// Mirrors the store's internal helper.
func sha256Hex(s string) string {
	h := sha256.Sum256([]byte(s))
	return hex.EncodeToString(h[:])
}
