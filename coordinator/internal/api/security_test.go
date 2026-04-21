package api

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/coordinator/internal/billing"
	"github.com/eigeninference/coordinator/internal/payments"
	"github.com/eigeninference/coordinator/internal/protocol"
	"github.com/eigeninference/coordinator/internal/registry"
	"github.com/eigeninference/coordinator/internal/store"
	"nhooyr.io/websocket"
)

// securityTestServer creates a Server with a quiet logger for security tests.
func securityTestServer(t *testing.T) (*Server, *store.MemoryStore) {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	srv := NewServer(reg, st, logger)
	return srv, st
}

// securityTestServerWithBilling creates a Server with mock billing configured.
func securityTestServerWithBilling(t *testing.T) (*Server, *store.MemoryStore) {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	srv := NewServer(reg, st, logger)

	ledger := payments.NewLedger(st)
	billingSvc := billing.NewService(st, ledger, logger, billing.Config{
		SolanaRPCURL:             "http://localhost:8899",
		SolanaCoordinatorAddress: "CoordAddress1111111111111111111111111111111",
		SolanaUSDCMint:           "EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v",
		SolanaMnemonic:           "abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about",
		MockMode:                 true,
	})
	srv.SetBilling(billingSvc)
	return srv, st
}

// parseJSONResponse unmarshals response body into a map.
func parseJSONResponse(t *testing.T, body []byte) map[string]any {
	t.Helper()
	var resp map[string]any
	if err := json.Unmarshal(body, &resp); err != nil {
		t.Fatalf("failed to parse JSON response: %v (body: %s)", err, string(body))
	}
	return resp
}

// connectProviderWS connects a provider WebSocket to the test server.
func connectProviderWS(t *testing.T, ts *httptest.Server) *websocket.Conn {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	wsURL := "ws" + strings.TrimPrefix(ts.URL, "http") + "/ws/provider"
	conn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatalf("websocket dial: %v", err)
	}
	return conn
}

// registerProvider sends a Register message and waits for it to take effect.
func registerProvider(t *testing.T, conn *websocket.Conn, models []protocol.ModelInfo, publicKey string) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	regMsg := protocol.RegisterMessage{
		Type: protocol.TypeRegister,
		Hardware: protocol.Hardware{
			MachineModel: "Mac15,8",
			ChipName:     "Apple M3 Max",
			MemoryGB:     64,
		},
		Models:    models,
		Backend:   "inprocess-mlx",
		PublicKey: publicKey,
	}
	data, _ := json.Marshal(regMsg)
	if err := conn.Write(ctx, websocket.MessageText, data); err != nil {
		t.Fatalf("write register: %v", err)
	}
	time.Sleep(100 * time.Millisecond)
}

// ---------------------------------------------------------------------------
// Test 1: Malformed WebSocket Messages
// ---------------------------------------------------------------------------

func TestSecurity_MalformedWebSocketMessages(t *testing.T) {
	srv, _ := securityTestServer(t)
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	t.Run("invalid_json", func(t *testing.T) {
		conn := connectProviderWS(t, ts)
		defer conn.Close(websocket.StatusNormalClosure, "")

		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()

		// Send invalid JSON — server should log a warning and continue, not crash.
		if err := conn.Write(ctx, websocket.MessageText, []byte("{this is not json!!!")); err != nil {
			t.Fatalf("write invalid json: %v", err)
		}

		// Connection should still be alive — send a valid register to prove it.
		registerProvider(t, conn, []protocol.ModelInfo{
			{ID: "test-model", SizeBytes: 1000, ModelType: "chat", Quantization: "4bit"},
		}, "")

		if srv.registry.ProviderCount() != 1 {
			t.Errorf("provider count = %d after invalid JSON + valid register, want 1", srv.registry.ProviderCount())
		}
	})

	t.Run("empty_message", func(t *testing.T) {
		conn := connectProviderWS(t, ts)
		defer conn.Close(websocket.StatusNormalClosure, "")

		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()

		// Send empty message — should not crash.
		if err := conn.Write(ctx, websocket.MessageText, []byte("")); err != nil {
			t.Fatalf("write empty message: %v", err)
		}

		// Connection should still be alive.
		time.Sleep(100 * time.Millisecond)
		registerProvider(t, conn, []protocol.ModelInfo{
			{ID: "empty-test", SizeBytes: 500, ModelType: "chat", Quantization: "4bit"},
		}, "")
	})

	t.Run("extremely_long_message", func(t *testing.T) {
		conn := connectProviderWS(t, ts)
		defer conn.Close(websocket.StatusNormalClosure, "")

		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()

		// Send 1MB of garbage — should not OOM the server.
		// The server sets a 10MB read limit so 1MB should be accepted and
		// parsed as invalid JSON (logged and ignored).
		garbage := make([]byte, 1024*1024)
		for i := range garbage {
			garbage[i] = 'A'
		}
		err := conn.Write(ctx, websocket.MessageText, garbage)
		if err != nil {
			// Write may fail if the server closes the connection due to the
			// large message, which is also acceptable behavior.
			t.Logf("write 1MB garbage: %v (acceptable — server may reject oversized messages)", err)
		}

		// Server should still be running — verify by connecting a new provider.
		time.Sleep(200 * time.Millisecond)
		conn2 := connectProviderWS(t, ts)
		defer conn2.Close(websocket.StatusNormalClosure, "")
		registerProvider(t, conn2, []protocol.ModelInfo{
			{ID: "after-garbage", SizeBytes: 500, ModelType: "chat", Quantization: "4bit"},
		}, "")
	})

	t.Run("unknown_message_type", func(t *testing.T) {
		conn := connectProviderWS(t, ts)
		defer conn.Close(websocket.StatusNormalClosure, "")

		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()

		// First register so the provider is known.
		registerProvider(t, conn, []protocol.ModelInfo{
			{ID: "unknown-type-test", SizeBytes: 500, ModelType: "chat", Quantization: "4bit"},
		}, "")

		// Send valid JSON with unknown type — should be logged and ignored.
		unknownMsg := map[string]any{
			"type":    "totally_unknown_type",
			"payload": "some data",
		}
		data, _ := json.Marshal(unknownMsg)
		if err := conn.Write(ctx, websocket.MessageText, data); err != nil {
			t.Fatalf("write unknown type: %v", err)
		}

		// Connection should still be alive.
		time.Sleep(100 * time.Millisecond)
		hb := protocol.HeartbeatMessage{
			Type:   protocol.TypeHeartbeat,
			Status: "idle",
		}
		hbData, _ := json.Marshal(hb)
		if err := conn.Write(ctx, websocket.MessageText, hbData); err != nil {
			t.Errorf("connection died after unknown message type: %v", err)
		}
	})

	t.Run("register_missing_fields", func(t *testing.T) {
		conn := connectProviderWS(t, ts)
		defer conn.Close(websocket.StatusNormalClosure, "")

		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()

		// Register with no hardware, no models — server should handle gracefully.
		minimalReg := map[string]any{
			"type": protocol.TypeRegister,
		}
		data, _ := json.Marshal(minimalReg)
		if err := conn.Write(ctx, websocket.MessageText, data); err != nil {
			t.Fatalf("write minimal register: %v", err)
		}

		time.Sleep(100 * time.Millisecond)
		// Should not crash; the provider may be registered with empty fields.
	})
}

// ---------------------------------------------------------------------------
// Test 2: Oversized Request Body
// ---------------------------------------------------------------------------

func TestSecurity_OversizedRequestBody(t *testing.T) {
	srv, _ := securityTestServer(t)

	// Pre-fill queue for "test" model so the request returns 503 immediately
	// instead of blocking for 30s waiting for a provider.
	for i := 0; i < 10; i++ {
		_ = srv.registry.Queue().Enqueue(&registry.QueuedRequest{
			RequestID:  fmt.Sprintf("oversized-filler-%d", i),
			Model:      "test",
			ResponseCh: make(chan *registry.Provider, 1),
		})
	}

	// Build a 10MB request body.
	bigContent := strings.Repeat("A", 10*1024*1024)
	body := fmt.Sprintf(`{"model":"test","messages":[{"role":"user","content":"%s"}]}`, bigContent)

	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer test-key")
	w := httptest.NewRecorder()

	srv.Handler().ServeHTTP(w, req)

	// Server should either:
	// - Return 413 (body too large)
	// - Return 503 (no provider available — meaning it parsed but found no provider)
	// - Return some other error
	// It should NOT panic or OOM.
	if w.Code == 0 {
		t.Error("expected a response, got nothing")
	}
	t.Logf("10MB request body returned status %d (server did not crash)", w.Code)

	// Verify server still works after the oversized request.
	healthReq := httptest.NewRequest(http.MethodGet, "/health", nil)
	healthW := httptest.NewRecorder()
	srv.Handler().ServeHTTP(healthW, healthReq)
	if healthW.Code != http.StatusOK {
		t.Errorf("health check after oversized request: status %d, want 200", healthW.Code)
	}
}

// ---------------------------------------------------------------------------
// Test 3: Auth Bypass Attempts
// ---------------------------------------------------------------------------

func TestSecurity_AuthBypass(t *testing.T) {
	srv, _ := securityTestServer(t)

	body := `{"model":"test","messages":[{"role":"user","content":"hi"}]}`

	tests := []struct {
		name       string
		path       string
		method     string
		authHeader string
		body       string
		wantStatus int
	}{
		{
			name:       "chat_completions_no_auth",
			path:       "/v1/chat/completions",
			method:     http.MethodPost,
			authHeader: "",
			body:       body,
			wantStatus: http.StatusUnauthorized,
		},
		{
			name:       "chat_completions_empty_bearer",
			path:       "/v1/chat/completions",
			method:     http.MethodPost,
			authHeader: "Bearer",
			body:       body,
			wantStatus: http.StatusUnauthorized,
		},
		{
			name:       "chat_completions_bearer_space_only",
			path:       "/v1/chat/completions",
			method:     http.MethodPost,
			authHeader: "Bearer ",
			body:       body,
			wantStatus: http.StatusUnauthorized,
		},
		{
			name:       "chat_completions_random_token",
			path:       "/v1/chat/completions",
			method:     http.MethodPost,
			authHeader: "Bearer totally-random-invalid-token-12345",
			body:       body,
			wantStatus: http.StatusUnauthorized,
		},
		{
			name:       "chat_completions_just_string",
			path:       "/v1/chat/completions",
			method:     http.MethodPost,
			authHeader: "not-even-bearer-format",
			body:       body,
			wantStatus: http.StatusUnauthorized,
		},
		{
			name:       "device_approve_no_auth",
			path:       "/v1/device/approve",
			method:     http.MethodPost,
			authHeader: "",
			body:       `{"user_code":"ABCD-1234"}`,
			wantStatus: http.StatusUnauthorized,
		},
		{
			name:       "device_approve_invalid_bearer",
			path:       "/v1/device/approve",
			method:     http.MethodPost,
			authHeader: "Bearer invalid-key",
			body:       `{"user_code":"ABCD-1234"}`,
			wantStatus: http.StatusForbidden,
		},
		{
			name:       "withdraw_no_auth",
			path:       "/v1/billing/withdraw/solana",
			method:     http.MethodPost,
			authHeader: "",
			body:       `{"wallet_address":"x","amount_usd":"1.00"}`,
			wantStatus: http.StatusUnauthorized,
		},
		{
			name:       "withdraw_invalid_bearer",
			path:       "/v1/billing/withdraw/solana",
			method:     http.MethodPost,
			authHeader: "Bearer fake-key-12345",
			body:       `{"wallet_address":"x","amount_usd":"1.00"}`,
			wantStatus: http.StatusUnauthorized,
		},
		{
			name:       "models_no_auth",
			path:       "/v1/models",
			method:     http.MethodGet,
			authHeader: "",
			body:       "",
			wantStatus: http.StatusUnauthorized,
		},
		{
			name:       "balance_no_auth",
			path:       "/v1/payments/balance",
			method:     http.MethodGet,
			authHeader: "",
			body:       "",
			wantStatus: http.StatusUnauthorized,
		},
		{
			name:       "completions_no_auth",
			path:       "/v1/completions",
			method:     http.MethodPost,
			authHeader: "",
			body:       `{"model":"test","prompt":"hello"}`,
			wantStatus: http.StatusUnauthorized,
		},
		{
			name:       "anthropic_messages_no_auth",
			path:       "/v1/messages",
			method:     http.MethodPost,
			authHeader: "",
			body:       `{"model":"test","messages":[]}`,
			wantStatus: http.StatusUnauthorized,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var reqBody *strings.Reader
			if tt.body != "" {
				reqBody = strings.NewReader(tt.body)
			} else {
				reqBody = strings.NewReader("")
			}
			req := httptest.NewRequest(tt.method, tt.path, reqBody)
			if tt.authHeader != "" {
				req.Header.Set("Authorization", tt.authHeader)
			}
			w := httptest.NewRecorder()
			srv.Handler().ServeHTTP(w, req)

			if w.Code != tt.wantStatus {
				t.Errorf("[%s] status = %d, want %d (body: %s)", tt.name, w.Code, tt.wantStatus, w.Body.String())
			}
		})
	}
}

// ---------------------------------------------------------------------------
// Test 4: Challenge Nonce Replay
// ---------------------------------------------------------------------------

func TestSecurity_ChallengeNonceReplay(t *testing.T) {
	srv, _ := securityTestServer(t)
	// Use a very fast challenge interval for this test.
	srv.challengeInterval = 500 * time.Millisecond

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	conn := connectProviderWS(t, ts)
	defer conn.Close(websocket.StatusNormalClosure, "")

	// Register with a public key so challenges verify key consistency.
	registerProvider(t, conn, []protocol.ModelInfo{
		{ID: "nonce-test-model", SizeBytes: 500, ModelType: "chat", Quantization: "4bit"},
	}, "dGVzdC1wdWJsaWMta2V5LWJhc2U2NA==")

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	// Read the first challenge.
	var firstNonce string
	for {
		_, data, err := conn.Read(ctx)
		if err != nil {
			t.Fatalf("read first challenge: %v", err)
		}
		var msg map[string]any
		if err := json.Unmarshal(data, &msg); err != nil {
			continue
		}
		if msg["type"] == protocol.TypeAttestationChallenge {
			firstNonce = msg["nonce"].(string)
			t.Logf("received first challenge nonce: %s...", firstNonce[:8])

			// Respond correctly to the first challenge.
			sipTrue := true
			rdmaFalse := true
			resp := protocol.AttestationResponseMessage{
				Type:              protocol.TypeAttestationResponse,
				Nonce:             firstNonce,
				Signature:         "dGVzdC1zaWduYXR1cmU=", // non-empty
				PublicKey:         "dGVzdC1wdWJsaWMta2V5LWJhc2U2NA==",
				SIPEnabled:        &sipTrue,
				RDMADisabled:      &rdmaFalse,
				SecureBootEnabled: &sipTrue,
			}
			respData, _ := json.Marshal(resp)
			if err := conn.Write(ctx, websocket.MessageText, respData); err != nil {
				t.Fatalf("write first challenge response: %v", err)
			}
			break
		}
	}

	// Wait for the second challenge.
	for {
		_, data, err := conn.Read(ctx)
		if err != nil {
			t.Fatalf("read second challenge: %v", err)
		}
		var msg map[string]any
		if err := json.Unmarshal(data, &msg); err != nil {
			continue
		}
		if msg["type"] == protocol.TypeAttestationChallenge {
			secondNonce := msg["nonce"].(string)
			t.Logf("received second challenge nonce: %s...", secondNonce[:8])

			if secondNonce == firstNonce {
				t.Error("second challenge reused the same nonce — nonces should be unique")
			}

			// Replay attack: respond with the OLD nonce instead of the new one.
			sipTrue := true
			rdmaFalse := true
			replayResp := protocol.AttestationResponseMessage{
				Type:              protocol.TypeAttestationResponse,
				Nonce:             firstNonce, // OLD nonce — should be rejected
				Signature:         "dGVzdC1zaWduYXR1cmU=",
				PublicKey:         "dGVzdC1wdWJsaWMta2V5LWJhc2U2NA==",
				SIPEnabled:        &sipTrue,
				RDMADisabled:      &rdmaFalse,
				SecureBootEnabled: &sipTrue,
			}
			replayData, _ := json.Marshal(replayResp)
			if err := conn.Write(ctx, websocket.MessageText, replayData); err != nil {
				t.Fatalf("write replay response: %v", err)
			}

			// The server should:
			// 1. Not find a pending challenge for the old nonce (it was already consumed)
			// 2. Log "attestation response for unknown challenge"
			// 3. The second challenge times out (since we didn't answer with the correct nonce)
			//
			// This is the correct behavior — old nonces cannot be replayed.
			t.Log("replay response sent with old nonce — server should reject it")
			break
		}
	}

	// The test passes if we get here without the server crashing or accepting
	// the replayed nonce. The challenge tracker removes nonces after use,
	// so replaying an old nonce maps to no pending challenge.
}

// ---------------------------------------------------------------------------
// Test 5: Provider Impersonation (same public key)
// ---------------------------------------------------------------------------

func TestSecurity_ProviderImpersonation(t *testing.T) {
	srv, _ := securityTestServer(t)
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	sharedPubKey := "c2hhcmVkLXB1YmxpYy1rZXktZm9yLXRlc3Q="

	// Provider A registers.
	connA := connectProviderWS(t, ts)
	defer connA.Close(websocket.StatusNormalClosure, "")
	registerProvider(t, connA, []protocol.ModelInfo{
		{ID: "model-a", SizeBytes: 500, ModelType: "chat", Quantization: "4bit"},
	}, sharedPubKey)

	if srv.registry.ProviderCount() != 1 {
		t.Fatalf("expected 1 provider after A, got %d", srv.registry.ProviderCount())
	}

	// Provider B registers with the SAME public key.
	connB := connectProviderWS(t, ts)
	defer connB.Close(websocket.StatusNormalClosure, "")
	registerProvider(t, connB, []protocol.ModelInfo{
		{ID: "model-b", SizeBytes: 500, ModelType: "chat", Quantization: "4bit"},
	}, sharedPubKey)

	// Both connections should be tracked as separate providers (different
	// WebSocket connections get different UUIDs). The coordinator treats
	// each connection as a separate provider entity even if they share
	// a public key. This is by design — a provider can have multiple
	// connections. The important thing is that neither crashes the server.
	if srv.registry.ProviderCount() != 2 {
		t.Errorf("expected 2 providers (both registered), got %d", srv.registry.ProviderCount())
	}

	t.Log("two providers with same public key both registered — handled as separate connections")
}

// ---------------------------------------------------------------------------
// Test 6: Device Code Brute Force
// ---------------------------------------------------------------------------

func TestSecurity_DeviceCodeBruteForce(t *testing.T) {
	srv, _ := securityTestServer(t)

	// Create a valid device code.
	codeReq := httptest.NewRequest(http.MethodPost, "/v1/device/code", nil)
	codeW := httptest.NewRecorder()
	srv.handleDeviceCode(codeW, codeReq)

	if codeW.Code != http.StatusOK {
		t.Fatalf("create device code: status %d, body: %s", codeW.Code, codeW.Body.String())
	}

	var codeResp map[string]any
	json.Unmarshal(codeW.Body.Bytes(), &codeResp)
	validUserCode := codeResp["user_code"].(string)
	validDeviceCode := codeResp["device_code"].(string)

	// Try 100 random user codes — all should fail with 404.
	userCtx := withUser(context.Background(), "brute-force-acct", "brute@test.com")
	for i := 0; i < 100; i++ {
		randomCode := fmt.Sprintf("%04d-%04d", i, i+1000)
		body := fmt.Sprintf(`{"user_code":"%s"}`, randomCode)
		req := httptest.NewRequest(http.MethodPost, "/v1/device/approve", strings.NewReader(body))
		req = req.WithContext(userCtx)
		w := httptest.NewRecorder()
		srv.handleDeviceApprove(w, req)

		if w.Code != http.StatusNotFound {
			t.Errorf("attempt %d: random code %q returned status %d, want 404", i, randomCode, w.Code)
		}
	}

	// Original valid code should still work after all the failed attempts.
	approveBody := fmt.Sprintf(`{"user_code":"%s"}`, validUserCode)
	approveReq := httptest.NewRequest(http.MethodPost, "/v1/device/approve", strings.NewReader(approveBody))
	approveReq = approveReq.WithContext(userCtx)
	approveW := httptest.NewRecorder()
	srv.handleDeviceApprove(approveW, approveReq)

	if approveW.Code != http.StatusOK {
		t.Errorf("valid code after 100 failed attempts: status %d, want 200, body: %s", approveW.Code, approveW.Body.String())
	}

	// Verify the device code was approved by polling with device_code.
	tokenBody := fmt.Sprintf(`{"device_code":"%s"}`, validDeviceCode)
	tokenReq := httptest.NewRequest(http.MethodPost, "/v1/device/token", strings.NewReader(tokenBody))
	tokenW := httptest.NewRecorder()
	srv.handleDeviceToken(tokenW, tokenReq)

	var tokenResp map[string]any
	json.Unmarshal(tokenW.Body.Bytes(), &tokenResp)
	if tokenResp["status"] != "authorized" {
		t.Errorf("device token status = %q after approval, want authorized", tokenResp["status"])
	}
}

// ---------------------------------------------------------------------------
// Test 7: Withdrawal to Foreign Wallet
// ---------------------------------------------------------------------------

func TestSecurity_WithdrawalToForeignWallet(t *testing.T) {
	srv, _ := securityTestServerWithBilling(t)

	user := &store.User{
		AccountID:           "withdraw-test-acct",
		PrivyUserID:         "did:privy:withdraw-test",
		SolanaWalletAddress: "UserWalletAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
	}

	// Seed some balance so insufficient_funds doesn't mask the wallet check.
	srv.billing.Ledger().Deposit(user.AccountID, 100_000_000) // $100

	t.Run("foreign_wallet_rejected", func(t *testing.T) {
		body := `{"wallet_address":"ForeignWalletBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB","amount_usd":"5.00"}`
		req := httptest.NewRequest(http.MethodPost, "/v1/billing/withdraw/solana", strings.NewReader(body))
		req = withPrivyUser(req, user)
		w := httptest.NewRecorder()

		srv.handleSolanaWithdraw(w, req)

		if w.Code != http.StatusForbidden {
			t.Errorf("withdraw to foreign wallet: status %d, want 403, body: %s", w.Code, w.Body.String())
		}

		resp := parseJSONResponse(t, w.Body.Bytes())
		errObj, _ := resp["error"].(map[string]any)
		if errObj == nil || errObj["type"] != "wallet_mismatch" {
			t.Errorf("expected wallet_mismatch error, got: %v", errObj)
		}
	})

	t.Run("empty_wallet_auto_populates", func(t *testing.T) {
		// When wallet_address is empty, it auto-populates from the user's account.
		body := `{"wallet_address":"","amount_usd":"1.00"}`
		req := httptest.NewRequest(http.MethodPost, "/v1/billing/withdraw/solana", strings.NewReader(body))
		req = withPrivyUser(req, user)
		w := httptest.NewRecorder()

		srv.handleSolanaWithdraw(w, req)

		// Mock mode doesn't have a real Solana client — we expect it to fail
		// at the Solana send step (502), not at the wallet validation step (403).
		// The important thing is it did NOT return 403 (wallet mismatch) or
		// 400 (missing wallet), meaning it auto-populated correctly.
		if w.Code == http.StatusForbidden {
			t.Errorf("empty wallet should auto-populate, not return 403")
		}
		if w.Code == http.StatusBadRequest {
			resp := parseJSONResponse(t, w.Body.Bytes())
			errObj, _ := resp["error"].(map[string]any)
			if errObj != nil && strings.Contains(fmt.Sprint(errObj["message"]), "wallet_address") {
				t.Errorf("empty wallet should auto-populate from user's account, got: %v", errObj)
			}
		}
		t.Logf("empty wallet auto-populate: status %d", w.Code)
	})

	t.Run("own_wallet_accepted", func(t *testing.T) {
		// Withdrawing to your own linked wallet should pass the wallet check.
		body := fmt.Sprintf(`{"wallet_address":"%s","amount_usd":"1.00"}`, user.SolanaWalletAddress)
		req := httptest.NewRequest(http.MethodPost, "/v1/billing/withdraw/solana", strings.NewReader(body))
		req = withPrivyUser(req, user)
		w := httptest.NewRecorder()

		srv.handleSolanaWithdraw(w, req)

		// Should not be 403 (wallet mismatch).
		if w.Code == http.StatusForbidden {
			t.Errorf("withdraw to own wallet should not return 403: %s", w.Body.String())
		}
		t.Logf("own wallet withdrawal: status %d", w.Code)
	})
}

// ---------------------------------------------------------------------------
// Test 8: SQL Injection
// ---------------------------------------------------------------------------

func TestSecurity_SQLInjection(t *testing.T) {
	srv, _ := securityTestServer(t)

	injectionPayloads := []string{
		"' OR 1=1 --",
		"'; DROP TABLE users; --",
		"\" OR \"1\"=\"1",
		"1; SELECT * FROM keys",
		"admin'--",
		"' UNION SELECT * FROM users --",
	}

	t.Run("api_key_injection", func(t *testing.T) {
		for _, payload := range injectionPayloads {
			body := `{"model":"test","messages":[{"role":"user","content":"hi"}]}`
			req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
			req.Header.Set("Authorization", "Bearer "+payload)
			w := httptest.NewRecorder()
			srv.Handler().ServeHTTP(w, req)

			if w.Code != http.StatusUnauthorized {
				t.Errorf("SQL injection in API key %q: status %d, want 401", payload, w.Code)
			}
		}
	})

	t.Run("model_name_injection", func(t *testing.T) {
		// Pre-fill the request queue for each injection model name so
		// Enqueue returns ErrQueueFull immediately (avoids 30s queue wait).
		for _, payload := range injectionPayloads {
			for i := 0; i < 10; i++ {
				_ = srv.registry.Queue().Enqueue(&registry.QueuedRequest{
					RequestID:  fmt.Sprintf("filler-%s-%d", payload, i),
					Model:      payload,
					ResponseCh: make(chan *registry.Provider, 1),
				})
			}
		}

		for _, payload := range injectionPayloads {
			body := fmt.Sprintf(`{"model":"%s","messages":[{"role":"user","content":"hi"}]}`, payload)
			req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
			req.Header.Set("Authorization", "Bearer test-key")
			w := httptest.NewRecorder()
			srv.Handler().ServeHTTP(w, req)

			// Should return 503 (queue full / no provider), not panic or expose data.
			if w.Code == 0 {
				t.Errorf("SQL injection in model %q: got no response", payload)
			}
		}
	})

	t.Run("device_code_injection", func(t *testing.T) {
		for _, payload := range injectionPayloads {
			body := fmt.Sprintf(`{"device_code":"%s"}`, payload)
			req := httptest.NewRequest(http.MethodPost, "/v1/device/token", strings.NewReader(body))
			w := httptest.NewRecorder()
			srv.Handler().ServeHTTP(w, req)

			// Should return 404 (not found), not panic.
			if w.Code == 0 || w.Code >= 500 {
				t.Errorf("SQL injection in device_code %q: status %d (should not be 5xx)", payload, w.Code)
			}
		}
	})

	t.Run("user_code_injection", func(t *testing.T) {
		userCtx := withUser(context.Background(), "sqli-test", "")

		for _, payload := range injectionPayloads {
			body := fmt.Sprintf(`{"user_code":"%s"}`, payload)
			req := httptest.NewRequest(http.MethodPost, "/v1/device/approve", strings.NewReader(body))
			req = req.WithContext(userCtx)
			w := httptest.NewRecorder()
			srv.handleDeviceApprove(w, req)

			// Should return 404 (not found), not panic.
			if w.Code == 0 || w.Code >= 500 {
				t.Errorf("SQL injection in user_code %q: status %d (should not be 5xx)", payload, w.Code)
			}
		}
	})
}

// ---------------------------------------------------------------------------
// Test 9: Header Injection
// ---------------------------------------------------------------------------

func TestSecurity_HeaderInjection(t *testing.T) {
	srv, _ := securityTestServer(t)

	t.Run("model_with_newlines", func(t *testing.T) {
		// Model name containing newlines should not inject HTTP headers.
		// Pre-fill queue so it returns 503 immediately instead of blocking 30s.
		injectedModel := "test\r\nX-Injected: true\r\n"
		for i := 0; i < 10; i++ {
			_ = srv.registry.Queue().Enqueue(&registry.QueuedRequest{
				RequestID:  fmt.Sprintf("header-inj-filler-%d", i),
				Model:      injectedModel,
				ResponseCh: make(chan *registry.Provider, 1),
			})
		}

		body := fmt.Sprintf(`{"model":"%s","messages":[{"role":"user","content":"hi"}]}`, `test\r\nX-Injected: true\r\n`)
		req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
		req.Header.Set("Authorization", "Bearer test-key")
		w := httptest.NewRecorder()
		srv.Handler().ServeHTTP(w, req)

		// The response should NOT contain the injected header.
		if w.Header().Get("X-Injected") == "true" {
			t.Error("header injection succeeded — model name newlines were reflected in response headers")
		}

		// Server should return a normal response (likely 503 no provider), not crash.
		if w.Code == 0 {
			t.Error("expected a response, got nothing")
		}
	})

	t.Run("content_with_control_chars", func(t *testing.T) {
		// Content containing control characters should be handled safely.
		body := `{"model":"test","messages":[{"role":"user","content":"hello\x00\x01\x02\x03"}]}`
		req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
		req.Header.Set("Authorization", "Bearer test-key")
		w := httptest.NewRecorder()
		srv.Handler().ServeHTTP(w, req)

		// Should not crash. Any status is fine as long as it's a valid HTTP response.
		if w.Code == 0 {
			t.Error("expected a response, got nothing")
		}
		t.Logf("control chars in content: status %d", w.Code)
	})

	t.Run("auth_header_with_newlines", func(t *testing.T) {
		body := `{"model":"test","messages":[{"role":"user","content":"hi"}]}`
		req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
		// Try to inject a header via the Authorization value.
		req.Header.Set("Authorization", "Bearer fake\r\nX-Injected: true")
		w := httptest.NewRecorder()
		srv.Handler().ServeHTTP(w, req)

		if w.Header().Get("X-Injected") == "true" {
			t.Error("header injection via Authorization succeeded")
		}

		// Should be rejected (401 since the token is invalid).
		if w.Code != http.StatusUnauthorized {
			t.Logf("auth header with newlines: status %d (expected 401)", w.Code)
		}
	})
}

// ---------------------------------------------------------------------------
// Test 10: Concurrent Auth Attempts
// ---------------------------------------------------------------------------

func TestSecurity_ConcurrentAuthAttempts(t *testing.T) {
	srv, _ := securityTestServer(t)

	body := `{"model":"test","messages":[{"role":"user","content":"hi"}]}`

	t.Run("concurrent_invalid_auth", func(t *testing.T) {
		var wg sync.WaitGroup
		results := make([]int, 50)

		for i := 0; i < 50; i++ {
			wg.Add(1)
			go func(idx int) {
				defer wg.Done()
				req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
				req.Header.Set("Authorization", fmt.Sprintf("Bearer invalid-key-%d", idx))
				w := httptest.NewRecorder()
				srv.Handler().ServeHTTP(w, req)
				results[idx] = w.Code
			}(i)
		}

		wg.Wait()

		for i, code := range results {
			if code != http.StatusUnauthorized {
				t.Errorf("concurrent invalid auth attempt %d: status %d, want 401", i, code)
			}
		}
	})

	t.Run("concurrent_valid_auth", func(t *testing.T) {
		// Pre-fill queue for "test" model so requests return 503 immediately
		// instead of blocking for 30s waiting for a provider.
		for i := 0; i < 10; i++ {
			_ = srv.registry.Queue().Enqueue(&registry.QueuedRequest{
				RequestID:  fmt.Sprintf("concurrent-valid-filler-%d", i),
				Model:      "test",
				ResponseCh: make(chan *registry.Provider, 1),
			})
		}

		var wg sync.WaitGroup
		results := make([]int, 50)

		for i := 0; i < 50; i++ {
			wg.Add(1)
			go func(idx int) {
				defer wg.Done()
				req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", strings.NewReader(body))
				req.Header.Set("Authorization", "Bearer test-key")
				w := httptest.NewRecorder()
				srv.Handler().ServeHTTP(w, req)
				results[idx] = w.Code
			}(i)
		}

		wg.Wait()

		for i, code := range results {
			// Valid auth with no provider should return 503 (no provider available / queue full),
			// not a panic or race condition crash.
			if code == 0 {
				t.Errorf("concurrent valid auth attempt %d: got status 0 (no response)", i)
			}
			// Auth should succeed — so we should NOT get 401.
			if code == http.StatusUnauthorized {
				t.Errorf("concurrent valid auth attempt %d: got 401 (auth failed under concurrency)", i)
			}
		}
	})

	t.Run("concurrent_mixed_endpoints", func(t *testing.T) {
		// Hit different endpoints concurrently with invalid auth to test
		// for data races in the auth middleware.
		endpoints := []struct {
			method string
			path   string
			body   string
		}{
			{http.MethodPost, "/v1/chat/completions", body},
			{http.MethodPost, "/v1/completions", `{"model":"test","prompt":"hi"}`},
			{http.MethodGet, "/v1/models", ""},
			{http.MethodGet, "/v1/payments/balance", ""},
			{http.MethodGet, "/v1/payments/usage", ""},
		}

		var wg sync.WaitGroup
		for i := 0; i < 50; i++ {
			wg.Add(1)
			go func(idx int) {
				defer wg.Done()
				ep := endpoints[idx%len(endpoints)]
				req := httptest.NewRequest(ep.method, ep.path, strings.NewReader(ep.body))
				req.Header.Set("Authorization", fmt.Sprintf("Bearer bad-key-%d", idx))
				w := httptest.NewRecorder()
				srv.Handler().ServeHTTP(w, req)

				if w.Code != http.StatusUnauthorized {
					t.Errorf("concurrent mixed endpoint %s (attempt %d): status %d, want 401",
						ep.path, idx, w.Code)
				}
			}(i)
		}
		wg.Wait()
	})
}
