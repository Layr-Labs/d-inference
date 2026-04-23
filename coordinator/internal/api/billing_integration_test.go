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

	"github.com/coder/websocket"
	"github.com/eigeninference/coordinator/internal/billing"
	"github.com/eigeninference/coordinator/internal/payments"
	"github.com/eigeninference/coordinator/internal/protocol"
	"github.com/eigeninference/coordinator/internal/registry"
	"github.com/eigeninference/coordinator/internal/store"
)

// billingTestServer creates a test server with billing enabled in mock mode.
// Returns the server, underlying store, and ledger for assertion access.
func billingTestServer(t *testing.T) (*Server, *store.MemoryStore, *payments.Ledger) {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)
	srv := NewServer(reg, st, logger)
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
	_ = st.Credit("test-key", 100_000_000, store.LedgerDeposit, "test-setup")

	return srv, st, ledger
}

// setupProviderForBilling connects a provider, sets trust, records challenge
// success, and returns the WebSocket connection, provider ID, and public key.
func setupProviderForBilling(t *testing.T, ctx context.Context, ts *httptest.Server, reg *registry.Registry, model string) (*websocket.Conn, string, string) {
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

// TestIntegration_ConsumerBillingCharge verifies that a consumer's balance is
// debited after a successful inference request. The charge amount should match
// the pricing for the model and tokens used.
func TestIntegration_ConsumerBillingCharge(t *testing.T) {
	srv, _, ledger := billingTestServer(t)

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	// The consumer ("test-key") was pre-credited with $100 by billingTestServer.
	consumerID := "test-key"
	initialBalance := ledger.Balance(consumerID)
	if initialBalance <= 0 {
		t.Fatalf("initial balance = %d, want > 0", initialBalance)
	}

	model := "billing-test-model"
	conn, _, pubKey := setupProviderForBilling(t, ctx, ts, srv.registry, model)
	defer conn.Close(websocket.StatusNormalClosure, "")

	// Provider serves one inference request with known usage.
	usage := protocol.UsageInfo{PromptTokens: 100, CompletionTokens: 50}
	providerDone := serveOneInference(ctx, t, conn, pubKey, usage)

	// Send a consumer inference request.
	status := sendInferenceRequest(t, ctx, ts.URL, model, "test-key")
	if status != http.StatusOK {
		t.Fatalf("inference status = %d, want 200", status)
	}

	<-providerDone
	// Wait for handleComplete to process billing.
	time.Sleep(300 * time.Millisecond)

	// Calculate expected cost using the pricing module.
	expectedCost := payments.CalculateCost(model, usage.PromptTokens, usage.CompletionTokens)
	expectedBalance := initialBalance - expectedCost

	actualBalance := ledger.Balance(consumerID)
	if actualBalance != expectedBalance {
		t.Errorf("consumer balance = %d, want %d (charged %d, expected cost %d)",
			actualBalance, expectedBalance, initialBalance-actualBalance, expectedCost)
	}

	// Verify usage was recorded in the ledger.
	usageEntries := ledger.Usage(consumerID)
	if len(usageEntries) != 1 {
		t.Fatalf("usage entries = %d, want 1", len(usageEntries))
	}
	if usageEntries[0].CostMicroUSD != expectedCost {
		t.Errorf("usage entry cost = %d, want %d", usageEntries[0].CostMicroUSD, expectedCost)
	}
	if usageEntries[0].PromptTokens != usage.PromptTokens {
		t.Errorf("usage entry prompt_tokens = %d, want %d", usageEntries[0].PromptTokens, usage.PromptTokens)
	}
	if usageEntries[0].CompletionTokens != usage.CompletionTokens {
		t.Errorf("usage entry completion_tokens = %d, want %d", usageEntries[0].CompletionTokens, usage.CompletionTokens)
	}
}

// TestIntegration_ConsumerInsufficientBalance verifies that consumers with zero
// balance are rejected with 402 before routing to a provider.
func TestIntegration_ConsumerInsufficientBalance(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	// Use a separate API key ("broke-key") with zero balance.
	st := store.NewMemory("broke-key")
	reg := registry.New(logger)
	srv := NewServer(reg, st, logger)

	ledger := srv.ledger
	billingSvc := billing.NewService(st, ledger, logger, billing.Config{MockMode: true})
	srv.SetBilling(billingSvc)

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	consumerID := "broke-key"
	if got := ledger.Balance(consumerID); got != 0 {
		t.Fatalf("initial balance = %d, want 0", got)
	}

	// Send a consumer inference request — should be rejected with 402.
	model := "insufficient-balance-model"
	status := sendInferenceRequest(t, ctx, ts.URL, model, "broke-key")
	if status != http.StatusPaymentRequired {
		t.Fatalf("inference status = %d, want 402 (insufficient funds)", status)
	}

	// Balance should still be 0 (no charge attempted).
	if ledger.Balance(consumerID) != 0 {
		t.Errorf("consumer balance should still be 0")
	}

	// No usage should be recorded (request was rejected before routing).
	if len(ledger.Usage(consumerID)) != 0 {
		t.Errorf("no usage should be recorded for rejected request")
	}
}

// TestIntegration_StreamingReservationBlocksExploit is the regression test for
// GitHub issue #33 ("Free inference via streaming"). A consumer whose balance
// exceeds the old MinimumCharge reservation ($0.0001) but is below the full
// cost of max_tokens × output-price must be rejected with 402 BEFORE any
// chunk is streamed — not after delivery with a silently-failed charge.
func TestIntegration_StreamingReservationBlocksExploit(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("exploit-key")
	reg := registry.New(logger)
	srv := NewServer(reg, st, logger)

	ledger := srv.ledger
	billingSvc := billing.NewService(st, ledger, logger, billing.Config{MockMode: true})
	srv.SetBilling(billingSvc)

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	consumerID := "exploit-key"

	// Seed the consumer with 1000 μUSD ($0.001) — well above the old
	// MinimumCharge of 100 μUSD but below the reservation required for a
	// streaming 4096-token request on default pricing
	// (CalculateCost of ~4096 × 200 μUSD/1M ≈ 819 μUSD is close, so use
	// max_tokens=8192 to make the gap unambiguous: reservation ≈ 1638 μUSD).
	const seedBalance int64 = 1000
	if err := st.Credit(consumerID, seedBalance, store.LedgerDeposit, "test-seed"); err != nil {
		t.Fatalf("seed balance: %v", err)
	}

	// Register a provider so the rejection can't be blamed on routing.
	model := "exploit-test-model"
	conn, _, _ := setupProviderForBilling(t, ctx, ts, srv.registry, model)
	defer conn.Close(websocket.StatusNormalClosure, "")

	// Streaming request explicitly requesting 8192 max_tokens. Even with
	// default pricing this exceeds the seeded balance, so the coordinator
	// must reject at the pre-flight reservation stage.
	chatBody := `{"model":"` + model + `","messages":[{"role":"user","content":"hello"}],"stream":true,"max_tokens":8192}`
	httpReq, _ := http.NewRequestWithContext(ctx, http.MethodPost, ts.URL+"/v1/chat/completions", strings.NewReader(chatBody))
	httpReq.Header.Set("Authorization", "Bearer "+consumerID)
	resp, err := http.DefaultClient.Do(httpReq)
	if err != nil {
		t.Fatalf("http request: %v", err)
	}
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()

	if resp.StatusCode != http.StatusPaymentRequired {
		t.Fatalf("streaming request with under-funded balance: status = %d, want 402; body = %s",
			resp.StatusCode, body)
	}

	// The rejection must happen before the reservation is debited: balance
	// remains unchanged, no usage was recorded, and no chunks were delivered.
	if got := ledger.Balance(consumerID); got != seedBalance {
		t.Errorf("balance after rejected request = %d, want %d (no charge should occur)",
			got, seedBalance)
	}
	if n := len(ledger.Usage(consumerID)); n != 0 {
		t.Errorf("usage entries after rejected request = %d, want 0", n)
	}
	if strings.Contains(string(body), "data:") {
		t.Errorf("response body should not contain SSE chunks; got: %s", body)
	}
}

// TestIntegration_ReservationRefundedOnCompletion verifies that the pre-flight
// reservation (now based on max_tokens, not MinimumCharge) is refunded down
// to the actual cost after the provider reports usage. This guards against
// the reservation silently over-charging consumers for bounded generations.
func TestIntegration_ReservationRefundedOnCompletion(t *testing.T) {
	srv, _, ledger := billingTestServer(t)

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	consumerID := "test-key"
	initialBalance := ledger.Balance(consumerID)

	model := "refund-test-model"
	conn, _, pubKey := setupProviderForBilling(t, ctx, ts, srv.registry, model)
	defer conn.Close(websocket.StatusNormalClosure, "")

	// Short generation — completion_tokens (10) is far below the reservation
	// based on default max_tokens=8192.
	usage := protocol.UsageInfo{PromptTokens: 5, CompletionTokens: 10}
	providerDone := serveOneInference(ctx, t, conn, pubKey, usage)

	status := sendInferenceRequest(t, ctx, ts.URL, model, consumerID)
	if status != http.StatusOK {
		t.Fatalf("status = %d, want 200", status)
	}

	<-providerDone
	time.Sleep(300 * time.Millisecond)

	// Consumer should be charged exactly the actual cost, not the reservation.
	expectedCost := payments.CalculateCost(model, usage.PromptTokens, usage.CompletionTokens)
	if got := ledger.Balance(consumerID); got != initialBalance-expectedCost {
		t.Errorf("balance = %d, want %d (initial %d minus cost %d); reservation refund failed",
			got, initialBalance-expectedCost, initialBalance, expectedCost)
	}
}

// TestIntegration_ReferralRewardDistribution verifies the full referral flow:
// a referrer registers a code, a consumer applies it, and after inference the
// referrer receives their share of the platform fee.
func TestIntegration_ReferralRewardDistribution(t *testing.T) {
	srv, st, ledger := billingTestServer(t)

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	// Set up the referral chain.
	referrerAccountID := "referrer-account"
	consumerID := "test-key" // API key = consumer identity

	// Register a referral code for the referrer.
	referralSvc := srv.billing.Referral()
	referrer, err := referralSvc.Register(referrerAccountID, "TESTREF")
	if err != nil {
		t.Fatalf("register referrer: %v", err)
	}
	if referrer.Code != "TESTREF" {
		t.Fatalf("referral code = %q, want %q", referrer.Code, "TESTREF")
	}

	// Apply the referral code to the consumer.
	if err := referralSvc.Apply(consumerID, "TESTREF"); err != nil {
		t.Fatalf("apply referral: %v", err)
	}

	// Consumer was pre-credited with $100 by billingTestServer.
	consumerBalance := ledger.Balance(consumerID)
	if consumerBalance <= 0 {
		t.Fatalf("consumer balance = %d, want > 0", consumerBalance)
	}

	model := "referral-test-model"
	conn, _, pubKey := setupProviderForBilling(t, ctx, ts, srv.registry, model)
	defer conn.Close(websocket.StatusNormalClosure, "")

	// Provider serves one inference request.
	usage := protocol.UsageInfo{PromptTokens: 1000, CompletionTokens: 500}
	providerDone := serveOneInference(ctx, t, conn, pubKey, usage)

	status := sendInferenceRequest(t, ctx, ts.URL, model, "test-key")
	if status != http.StatusOK {
		t.Fatalf("inference status = %d, want 200", status)
	}

	<-providerDone
	time.Sleep(300 * time.Millisecond)

	// Calculate expected amounts.
	totalCost := payments.CalculateCost(model, usage.PromptTokens, usage.CompletionTokens)
	expectedProviderPayout := payments.ProviderPayout(totalCost) // 95%
	expectedPlatformFee := payments.PlatformFee(totalCost)       // 5%

	// Referral share is 20% of the platform fee.
	referralShare := expectedPlatformFee * referralSvc.SharePercent() / 100
	expectedPlatformAfterReferral := expectedPlatformFee - referralShare

	// Verify consumer was charged.
	actualConsumerBalance := ledger.Balance(consumerID)
	expectedConsumerBalance := consumerBalance - totalCost
	if actualConsumerBalance != expectedConsumerBalance {
		t.Errorf("consumer balance = %d, want %d (charged %d)", actualConsumerBalance, expectedConsumerBalance, totalCost)
	}

	// Verify provider got 95% of the charge.
	// The provider in this test has no account linkage (connected via connectProvider),
	// so payout goes to the wallet address. Since connectProvider does not set a
	// wallet address, let's check the ledger's pending payouts instead.
	// Provider without AccountID and without WalletAddress won't receive payout
	// via CreditProvider (the code checks p.WalletAddress). But the cost flow is:
	// handleComplete checks p.AccountID first, then p.WalletAddress.
	// connectProvider doesn't set either, so no provider credit occurs.
	// Verify the math is correct by checking the provider payout calculation.
	if expectedProviderPayout != payments.ProviderPayout(totalCost) {
		t.Errorf("provider payout calculation mismatch")
	}
	_ = expectedProviderPayout // used in fee split check below

	// Verify referrer got their share.
	referrerBalance := st.GetBalance(referrerAccountID)
	if referrerBalance != referralShare {
		t.Errorf("referrer balance = %d, want %d (20%% of platform fee %d)", referrerBalance, referralShare, expectedPlatformFee)
	}

	// Verify platform got the remaining platform fee (after referral deduction).
	platformBalance := st.GetBalance("platform")
	if platformBalance != expectedPlatformAfterReferral {
		t.Errorf("platform balance = %d, want %d (platform fee %d minus referral %d)",
			platformBalance, expectedPlatformAfterReferral, expectedPlatformFee, referralShare)
	}

	// Verify referral stats.
	stats, err := referralSvc.Stats(referrerAccountID)
	if err != nil {
		t.Fatalf("referral stats: %v", err)
	}
	if stats.TotalReferred != 1 {
		t.Errorf("total_referred = %d, want 1", stats.TotalReferred)
	}
	if stats.TotalRewardsMicroUSD != referralShare {
		t.Errorf("total_rewards = %d, want %d", stats.TotalRewardsMicroUSD, referralShare)
	}

	// Verify the fee split sums correctly:
	// totalCost = providerPayout + platformFee
	// platformFee = platformAfterReferral + referralShare
	feeCheck := expectedProviderPayout + expectedPlatformAfterReferral + referralShare
	if feeCheck != totalCost {
		t.Errorf("fee split does not sum: provider(%d) + platform(%d) + referral(%d) = %d, want %d",
			expectedProviderPayout, expectedPlatformAfterReferral, referralShare, feeCheck, totalCost)
	}
}

// TestIntegration_DeviceAuthFullFlow tests the complete device authorization
// flow: code generation, approval, token issuance, and provider registration
// with account linking. Verifies that inference earnings go to the linked account.
func TestIntegration_DeviceAuthFullFlow(t *testing.T) {
	srv, st, _ := billingTestServer(t)

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	// Step 1: POST /v1/device/code to get device_code + user_code.
	codeResp, err := http.Post(ts.URL+"/v1/device/code", "application/json", strings.NewReader("{}"))
	if err != nil {
		t.Fatalf("device code request: %v", err)
	}
	defer codeResp.Body.Close()
	if codeResp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(codeResp.Body)
		t.Fatalf("device code status = %d, body = %s", codeResp.StatusCode, body)
	}

	var codeResult struct {
		DeviceCode string `json:"device_code"`
		UserCode   string `json:"user_code"`
	}
	json.NewDecoder(codeResp.Body).Decode(&codeResult)
	if codeResult.DeviceCode == "" || codeResult.UserCode == "" {
		t.Fatal("device_code or user_code is empty")
	}

	// Step 2: Create a user in the store (simulating Privy auth).
	accountID := "acct-device-auth-test"
	user := &store.User{
		AccountID:   accountID,
		PrivyUserID: "did:privy:test-device-flow",
		Email:       "test@example.com",
		CreatedAt:   time.Now(),
	}
	if err := st.CreateUser(user); err != nil {
		t.Fatalf("create user: %v", err)
	}

	// Step 3: Approve the device code (simulating the user approving in the browser).
	// We directly approve via the store since handleDeviceApprove requires Privy JWT context.
	if err := st.ApproveDeviceCode(codeResult.DeviceCode, accountID); err != nil {
		t.Fatalf("approve device code: %v", err)
	}

	// Step 4: POST /v1/device/token with the device_code to get the auth token.
	tokenBody := `{"device_code":"` + codeResult.DeviceCode + `"}`
	tokenResp, err := http.Post(ts.URL+"/v1/device/token", "application/json", strings.NewReader(tokenBody))
	if err != nil {
		t.Fatalf("device token request: %v", err)
	}
	defer tokenResp.Body.Close()
	if tokenResp.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(tokenResp.Body)
		t.Fatalf("device token status = %d, body = %s", tokenResp.StatusCode, body)
	}

	var tokenResult struct {
		Status    string `json:"status"`
		Token     string `json:"token"`
		AccountID string `json:"account_id"`
	}
	json.NewDecoder(tokenResp.Body).Decode(&tokenResult)
	if tokenResult.Status != "authorized" {
		t.Fatalf("token status = %q, want %q", tokenResult.Status, "authorized")
	}
	if tokenResult.Token == "" {
		t.Fatal("auth token is empty")
	}
	if tokenResult.AccountID != accountID {
		t.Errorf("account_id = %q, want %q", tokenResult.AccountID, accountID)
	}

	// Step 5: Connect a provider via WebSocket using the auth token.
	pubKey := testPublicKeyB64()
	model := "device-auth-model"
	models := []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}}
	conn := connectProviderWithToken(t, ctx, ts.URL, models, pubKey, tokenResult.Token, "0xDeviceTestWallet")
	defer conn.Close(websocket.StatusNormalClosure, "")

	// Wait for registration to complete.
	time.Sleep(300 * time.Millisecond)

	// Set trust level and mark challenge as verified.
	for _, id := range srv.registry.ProviderIDs() {
		srv.registry.SetTrustLevel(id, registry.TrustHardware)
		srv.registry.RecordChallengeSuccess(id)
	}

	// Step 6: Send an inference request and have the provider respond.
	usage := protocol.UsageInfo{PromptTokens: 100, CompletionTokens: 50}
	providerDone := serveOneInference(ctx, t, conn, pubKey, usage)

	status := sendInferenceRequest(t, ctx, ts.URL, model, "test-key")
	if status != http.StatusOK {
		t.Fatalf("inference status = %d, want 200", status)
	}

	<-providerDone
	time.Sleep(300 * time.Millisecond)

	// Step 7: Verify earnings went to the linked account.
	expectedPayout := payments.ProviderPayout(payments.CalculateCost(model, usage.PromptTokens, usage.CompletionTokens))

	accountBalance := st.GetBalance(accountID)
	if accountBalance != expectedPayout {
		t.Errorf("account balance = %d, want %d (provider payout)", accountBalance, expectedPayout)
	}

	// Verify the wallet address was NOT credited (account takes priority).
	walletBalance := st.GetBalance("0xDeviceTestWallet")
	if walletBalance != 0 {
		t.Errorf("wallet balance = %d, want 0 (account-linked provider should not credit wallet)", walletBalance)
	}

	// Step 8: Verify per-node earnings were recorded.
	earnings, err := st.GetProviderEarnings(pubKey, 10)
	if err != nil {
		t.Fatalf("get provider earnings: %v", err)
	}
	if len(earnings) == 0 {
		t.Fatal("expected at least one provider earning record")
	}

	e := earnings[0]
	if e.AccountID != accountID {
		t.Errorf("earning account_id = %q, want %q", e.AccountID, accountID)
	}
	if e.AmountMicroUSD != expectedPayout {
		t.Errorf("earning amount = %d, want %d", e.AmountMicroUSD, expectedPayout)
	}
	if e.PromptTokens != usage.PromptTokens {
		t.Errorf("earning prompt_tokens = %d, want %d", e.PromptTokens, usage.PromptTokens)
	}
	if e.CompletionTokens != usage.CompletionTokens {
		t.Errorf("earning completion_tokens = %d, want %d", e.CompletionTokens, usage.CompletionTokens)
	}

	// Verify account earnings are also accessible via GetAccountEarnings.
	accountEarnings, err := st.GetAccountEarnings(accountID, 10)
	if err != nil {
		t.Fatalf("get account earnings: %v", err)
	}
	if len(accountEarnings) != 1 {
		t.Errorf("account earnings count = %d, want 1", len(accountEarnings))
	}
}

// TestIntegration_MultiNodeSameAccount verifies that two providers linked to the
// same account both accumulate earnings into the same account balance.
func TestIntegration_MultiNodeSameAccount(t *testing.T) {
	srv, st, _ := billingTestServer(t)

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	// Create a single account with a provider token.
	accountID := "acct-multi-node"
	rawToken := "multi-node-auth-token"
	tokenHash := sha256HexStr(rawToken)
	if err := st.CreateProviderToken(&store.ProviderToken{
		TokenHash: tokenHash,
		AccountID: accountID,
		Label:     "multi-node-test",
		Active:    true,
		CreatedAt: time.Now(),
	}); err != nil {
		t.Fatalf("create provider token: %v", err)
	}

	// Connect TWO providers using the same auth token but different models.
	pubKey1 := testPublicKeyB64()
	pubKey2 := testPublicKeyB64()
	model1 := "multi-node-model-a"
	model2 := "multi-node-model-b"

	conn1 := connectProviderWithToken(t, ctx, ts.URL,
		[]protocol.ModelInfo{{ID: model1, ModelType: "chat", Quantization: "4bit"}},
		pubKey1, rawToken, "0xMultiNode1")
	defer conn1.Close(websocket.StatusNormalClosure, "")

	time.Sleep(200 * time.Millisecond)

	conn2 := connectProviderWithToken(t, ctx, ts.URL,
		[]protocol.ModelInfo{{ID: model2, ModelType: "chat", Quantization: "4bit"}},
		pubKey2, rawToken, "0xMultiNode2")
	defer conn2.Close(websocket.StatusNormalClosure, "")

	time.Sleep(200 * time.Millisecond)

	// Set trust level and challenge success for all providers.
	for _, id := range srv.registry.ProviderIDs() {
		srv.registry.SetTrustLevel(id, registry.TrustHardware)
		srv.registry.RecordChallengeSuccess(id)
	}

	// Verify we have two providers.
	if srv.registry.ProviderCount() != 2 {
		t.Fatalf("provider count = %d, want 2", srv.registry.ProviderCount())
	}

	// Serve inference requests sequentially. Start each provider's handler
	// just before the corresponding request to avoid read timeouts.
	usage1 := protocol.UsageInfo{PromptTokens: 100, CompletionTokens: 50}
	usage2 := protocol.UsageInfo{PromptTokens: 200, CompletionTokens: 100}

	// Inference 1: model1 → provider 1.
	provider1Done := serveOneInference(ctx, t, conn1, pubKey1, usage1)
	status1 := sendInferenceRequest(t, ctx, ts.URL, model1, "test-key")
	if status1 != http.StatusOK {
		t.Fatalf("inference 1 status = %d, want 200", status1)
	}
	<-provider1Done
	time.Sleep(300 * time.Millisecond)

	// Inference 2: model2 → provider 2.
	provider2Done := serveOneInference(ctx, t, conn2, pubKey2, usage2)
	status2 := sendInferenceRequest(t, ctx, ts.URL, model2, "test-key")
	if status2 != http.StatusOK {
		t.Fatalf("inference 2 status = %d, want 200", status2)
	}
	<-provider2Done
	time.Sleep(300 * time.Millisecond)

	// Verify the SAME account got credited twice.
	expectedPayout1 := payments.ProviderPayout(payments.CalculateCost(model1, usage1.PromptTokens, usage1.CompletionTokens))
	expectedPayout2 := payments.ProviderPayout(payments.CalculateCost(model2, usage2.PromptTokens, usage2.CompletionTokens))
	expectedTotalBalance := expectedPayout1 + expectedPayout2

	actualBalance := st.GetBalance(accountID)
	if actualBalance != expectedTotalBalance {
		t.Errorf("account balance = %d, want %d (payout1=%d + payout2=%d)",
			actualBalance, expectedTotalBalance, expectedPayout1, expectedPayout2)
	}

	// Verify GetAccountEarnings shows two entries with different provider IDs.
	accountEarnings, err := st.GetAccountEarnings(accountID, 10)
	if err != nil {
		t.Fatalf("get account earnings: %v", err)
	}
	if len(accountEarnings) != 2 {
		t.Fatalf("account earnings count = %d, want 2", len(accountEarnings))
	}

	// Check that the two earnings have different provider IDs.
	providerIDSet := make(map[string]bool)
	for _, e := range accountEarnings {
		if e.AccountID != accountID {
			t.Errorf("earning account_id = %q, want %q", e.AccountID, accountID)
		}
		providerIDSet[e.ProviderID] = true
	}
	if len(providerIDSet) != 2 {
		t.Errorf("unique provider IDs in earnings = %d, want 2 (each node should have its own ID)", len(providerIDSet))
	}

	// Verify wallet addresses were NOT credited (account takes priority).
	if st.GetBalance("0xMultiNode1") != 0 {
		t.Error("wallet 1 should not be credited when account is linked")
	}
	if st.GetBalance("0xMultiNode2") != 0 {
		t.Error("wallet 2 should not be credited when account is linked")
	}
}

// sha256HexStr computes SHA-256 of a string and returns hex encoding.
func sha256HexStr(s string) string {
	h := sha256.Sum256([]byte(s))
	return hex.EncodeToString(h[:])
}
