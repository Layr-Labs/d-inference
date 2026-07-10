package api

// Billing integration tests for Darkbloom coordinator.
//
// These tests exercise the full billing flow end-to-end: consumer balance
// checking, inference charging, referral reward distribution, device auth
// linking, and multi-node account earnings.

import (
	"context"
	"errors"
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

func (s failingCreditStore) Credit(accountID string, amountMicroUSD int64, entryType store.LedgerEntryType, reference string) error {
	return errors.New("forced credit failure")
}

func (s failingCreditStore) CreditReservationRelease(accountID string, totalMicroUSD, withdrawableMicroUSD int64, entryType store.LedgerEntryType, reference string) error {
	return errors.New("forced credit failure")
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
	consumerID := testConsumerID
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
	st := store.NewMemory(store.Config{AdminKey: "broke-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)

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
	st := store.NewMemory(store.Config{AdminKey: "exploit-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)

	ledger := srv.ledger
	billingSvc := billing.NewService(st, ledger, logger, billing.Config{MockMode: true})
	srv.SetBilling(billingSvc)

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	// The bearer token is the raw "exploit-key"; the ledger tracks it under the
	// derived non-secret identity (the key is unlinked).
	consumerID := store.LegacyAccountID("exploit-key")

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
	httpReq.Header.Set("Authorization", "Bearer exploit-key")
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

	consumerID := testConsumerID
	initialBalance := ledger.Balance(consumerID)

	model := "refund-test-model"
	conn, _, pubKey := setupProviderForBilling(t, ctx, ts, srv.registry, model)
	defer conn.Close(websocket.StatusNormalClosure, "")

	// Short generation — completion_tokens (10) is far below the reservation
	// based on default max_tokens=8192.
	usage := protocol.UsageInfo{PromptTokens: 5, CompletionTokens: 10}
	providerDone := serveOneInference(ctx, t, conn, pubKey, usage)

	status := sendInferenceRequest(t, ctx, ts.URL, model, "test-key")
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

// TestIntegration_ReservationRefundedOnCommittedProviderError verifies that a
// provider failure after the first chunk does not leave the whole pre-flight
// reservation deducted. No completion usage is available, so the reservation is
// refunded and no usage is recorded.
func TestIntegration_ReservationRefundedOnCommittedProviderError(t *testing.T) {
	srv, _, ledger := billingTestServer(t)

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	consumerID := testConsumerID
	initialBalance := ledger.Balance(consumerID)

	model := "refund-error-model"
	conn, _, pubKey := setupProviderForBilling(t, ctx, ts, srv.registry, model)
	defer conn.Close(websocket.StatusNormalClosure, "")
	providerDone := serveChunkThenProviderError(ctx, t, conn, pubKey, http.StatusBadGateway)

	chatBody := `{"model":"` + model + `","messages":[{"role":"user","content":"hello"}],"stream":false,"max_tokens":8192}`
	httpReq, _ := http.NewRequestWithContext(ctx, http.MethodPost, ts.URL+"/v1/chat/completions", strings.NewReader(chatBody))
	httpReq.Header.Set("Authorization", "Bearer test-key")

	resp, err := http.DefaultClient.Do(httpReq)
	if err != nil {
		t.Fatalf("http request: %v", err)
	}
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()

	<-providerDone
	time.Sleep(300 * time.Millisecond)

	if resp.StatusCode != http.StatusBadGateway {
		t.Fatalf("status = %d, want 502; body = %s", resp.StatusCode, body)
	}
	if got := ledger.Balance(consumerID); got != initialBalance {
		t.Errorf("balance after provider error = %d, want %d (reservation should be refunded)", got, initialBalance)
	}
	if got := len(ledger.Usage(consumerID)); got != 0 {
		t.Errorf("usage entries after provider error = %d, want 0", got)
	}
}

func TestIntegration_SuccessfulInferenceCreditsProviderAccount(t *testing.T) {
	srv, st, _ := billingTestServer(t)

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	model := "provider-account-paid-model"
	conn, providerID, pubKey := setupProviderForBilling(t, ctx, ts, srv.registry, model)
	defer conn.Close(websocket.StatusNormalClosure, "")

	// Get the account ID that was set by setupProviderForBilling.
	p := srv.registry.GetProvider(providerID)
	if p == nil {
		t.Fatal("provider not found")
	}
	p.Mu().Lock()
	accountID := p.AccountID
	p.Mu().Unlock()

	usage := protocol.UsageInfo{PromptTokens: 1000, CompletionTokens: 500}
	providerDone := serveOneInference(ctx, t, conn, pubKey, usage)

	status := sendInferenceRequest(t, ctx, ts.URL, model, "test-key")
	if status != http.StatusOK {
		t.Fatalf("inference status = %d, want 200", status)
	}

	<-providerDone
	time.Sleep(300 * time.Millisecond)

	// Verify provider account was credited with 95% of the inference cost.
	expectedPayout := payments.ProviderPayout(payments.CalculateCost(model, usage.PromptTokens, usage.CompletionTokens))
	if got := st.GetBalance(accountID); got != expectedPayout {
		t.Errorf("provider account balance = %d, want %d", got, expectedPayout)
	}
}

func TestIntegration_ProviderCustomPricePaidWithoutReservationClamp(t *testing.T) {
	srv, st, ledger := billingTestServer(t)

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	consumerID := testConsumerID
	initialBalance := ledger.Balance(consumerID)

	model := "provider-custom-price-model"
	const customInputPrice int64 = 50_000
	const customOutputPrice int64 = 10_000_000

	conn, providerID, pubKey := setupProviderForBilling(t, ctx, ts, srv.registry, model)
	defer conn.Close(websocket.StatusNormalClosure, "")

	// Get the account ID that was set by setupProviderForBilling to use as pricing key.
	p := srv.registry.GetProvider(providerID)
	if p == nil {
		t.Fatal("provider not found")
	}
	p.Mu().Lock()
	accountID := p.AccountID
	p.Mu().Unlock()

	if err := st.SetModelPrice(accountID, model, customInputPrice, customOutputPrice); err != nil {
		t.Fatalf("set provider custom price: %v", err)
	}

	usage := protocol.UsageInfo{PromptTokens: 1000, CompletionTokens: 500}
	providerDone := serveOneInference(ctx, t, conn, pubKey, usage)

	status := sendInferenceRequest(t, ctx, ts.URL, model, "test-key")
	if status != http.StatusOK {
		t.Fatalf("inference status = %d, want 200", status)
	}

	<-providerDone
	time.Sleep(300 * time.Millisecond)

	expectedCost := payments.CalculateCostWithOverrides(model, usage.PromptTokens, usage.CompletionTokens, customInputPrice, customOutputPrice, true)
	expectedPayout := payments.ProviderPayout(expectedCost)
	if got := st.GetBalance(accountID); got != expectedPayout {
		t.Errorf("provider account balance = %d, want %d", got, expectedPayout)
	}
	if got := ledger.Balance(consumerID); got != initialBalance-expectedCost {
		t.Errorf("consumer balance = %d, want %d", got, initialBalance-expectedCost)
	}
	usageEntries := ledger.Usage(consumerID)
	if len(usageEntries) != 1 {
		t.Fatalf("usage entries = %d, want 1", len(usageEntries))
	}
	if got := usageEntries[0].CostMicroUSD; got != expectedCost {
		t.Errorf("usage cost = %d, want %d", got, expectedCost)
	}
}

// Providers without a payout destination should still serve requests.
// Earnings are credited to the provider's internal ledger and can be
// withdrawn once they complete Stripe Connect onboarding.
func TestIntegration_BillingAllowsProviderWithoutPayoutDestination(t *testing.T) {
	srv, _, _ := billingTestServer(t)

	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	model := "no-payout-destination-model"
	conn, _, _ := setupProviderForBillingNoPayoutDestination(t, ctx, ts, srv.registry, model)
	defer conn.Close(websocket.StatusNormalClosure, "")

	status := sendInferenceRequest(t, ctx, ts.URL, model, "test-key")
	// Should NOT be 503 — providers without payout destination are allowed.
	if status == http.StatusServiceUnavailable {
		t.Fatalf("inference status = 503, providers without payout destination should be allowed")
	}
}
