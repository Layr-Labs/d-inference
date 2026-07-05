package api

// Billing integration tests for Darkbloom coordinator.
//
// These tests exercise the full billing flow end-to-end: consumer balance
// checking, inference charging, referral reward distribution, device auth
// linking, and multi-node account earnings.

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"nhooyr.io/websocket"
)

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
	consumerID := testConsumerID // API key = consumer identity

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
	conn, providerID, pubKey := setupProviderForBilling(t, ctx, ts, srv.registry, model)
	defer conn.Close(websocket.StatusNormalClosure, "")

	// Get the provider's account ID for payout verification.
	p := srv.registry.GetProvider(providerID)
	if p == nil {
		t.Fatal("provider not found")
	}
	p.Mu().Lock()
	providerAccountID := p.AccountID
	p.Mu().Unlock()

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
	expectedProviderPayout := payments.ProviderPayout(totalCost) // provider payout at the default fee
	expectedPlatformFee := payments.PlatformFee(totalCost)       // platform fee at the default rate (0% during alpha)

	// Referral share is a percentage of the platform fee (0 while the fee is 0).
	referralShare := expectedPlatformFee * referralSvc.SharePercent() / 100
	expectedPlatformAfterReferral := expectedPlatformFee - referralShare

	// Verify consumer was charged.
	actualConsumerBalance := ledger.Balance(consumerID)
	expectedConsumerBalance := consumerBalance - totalCost
	if actualConsumerBalance != expectedConsumerBalance {
		t.Errorf("consumer balance = %d, want %d (charged %d)", actualConsumerBalance, expectedConsumerBalance, totalCost)
	}

	// Verify the provider got their payout credited to their account.
	// setupProviderForBilling links the provider to an account via test-account-<id>.
	if got := st.GetBalance(providerAccountID); got != expectedProviderPayout {
		t.Errorf("provider account balance = %d, want %d (payout of totalCost %d)",
			got, expectedProviderPayout, totalCost)
	}

	// Verify referrer got their share.
	referrerBalance := st.GetBalance(referrerAccountID)
	if referrerBalance != referralShare {
		t.Errorf("referrer balance = %d, want %d (share of platform fee %d)", referrerBalance, referralShare, expectedPlatformFee)
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
	conn := connectProviderWithToken(t, ctx, ts.URL, models, pubKey, tokenResult.Token)
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
		pubKey1, rawToken)
	defer conn1.Close(websocket.StatusNormalClosure, "")

	time.Sleep(200 * time.Millisecond)

	conn2 := connectProviderWithToken(t, ctx, ts.URL,
		[]protocol.ModelInfo{{ID: model2, ModelType: "chat", Quantization: "4bit"}},
		pubKey2, rawToken)
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
