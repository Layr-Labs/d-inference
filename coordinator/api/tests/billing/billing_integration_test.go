package billing_test

// Billing integration tests for Darkbloom coordinator.
//
// These tests exercise the full billing flow end-to-end: consumer balance
// checking, inference charging, referral reward distribution, device auth
// linking, and multi-node account earnings.

import (
	"context"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/api/tests/internal/testkit"
	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
	"nhooyr.io/websocket"
)

// TestIntegration_ConsumerInsufficientBalance verifies that consumers with zero
// balance are rejected with 402 before routing to a provider.
func TestIntegration_ConsumerInsufficientBalance(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	// Use a separate API key ("broke-key") with zero balance.
	st := memory.NewMemory(store.Config{AdminKey: "broke-key"})
	reg := registry.New(logger)
	srv := newBillingFixture(t, reg, st, api.ServerConfig{}, logger)

	ledger := payments.NewLedger(st)
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
	if len(billingUsage(t, srv, "broke-key")) != 0 {
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
	st := memory.NewMemory(store.Config{AdminKey: "exploit-key"})
	reg := registry.New(logger)
	srv := newBillingFixture(t, reg, st, api.ServerConfig{}, logger)

	ledger := payments.NewLedger(st)
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
	// (Rates.CostWithMinimum of ~4096 × 200 μUSD/1M ≈ 819 μUSD is close, so use
	// max_tokens=8192 to make the gap unambiguous: reservation ≈ 1638 μUSD).
	const seedBalance int64 = 1000
	if err := st.Credit(consumerID, seedBalance, store.LedgerDeposit, "test-seed"); err != nil {
		t.Fatalf("seed balance: %v", err)
	}

	// Register a provider so the rejection can't be blamed on routing.
	model := "exploit-test-model"
	conn, _, _ := testkit.SetupProviderForBilling(t, ctx, ts, srv.registry, model)
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
	if n := len(billingUsage(t, srv, "exploit-key")); n != 0 {
		t.Errorf("usage entries after rejected request = %d, want 0", n)
	}
	if strings.Contains(string(body), "data:") {
		t.Errorf("response body should not contain SSE chunks; got: %s", body)
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
	conn, _, pubKey := testkit.SetupProviderForBilling(t, ctx, ts, srv.registry, model)
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

	if resp.StatusCode != http.StatusInternalServerError {
		t.Fatalf("status = %d, want canonical generation-failure 500; body = %s", resp.StatusCode, body)
	}
	if got := ledger.Balance(consumerID); got != initialBalance {
		t.Errorf("balance after provider error = %d, want %d (reservation should be refunded)", got, initialBalance)
	}
	if got := len(billingUsage(t, srv, "test-key")); got != 0 {
		t.Errorf("usage entries after provider error = %d, want 0", got)
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
	conn, _, pubKey := setupProviderForBillingNoPayoutDestination(t, ctx, ts, srv.registry, model)
	defer conn.Close(websocket.StatusNormalClosure, "")

	providerDone := testkit.ServeOneInference(ctx, t, conn, pubKey, protocol.UsageInfo{PromptTokens: 10, CompletionTokens: 5})
	status := sendInferenceRequest(t, ctx, ts.URL, model, "test-key")
	<-providerDone
	// Prove that inference actually completes; an SLA timeout is not success.
	if status != http.StatusOK {
		t.Fatalf("inference status = %d, want 200 without a payout destination", status)
	}
}
