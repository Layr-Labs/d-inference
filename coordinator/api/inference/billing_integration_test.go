package inference

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
	"nhooyr.io/websocket"
)

func (s failingCreditStore) Credit(accountID string, amountMicroUSD int64, entryType store.LedgerEntryType, reference string) error {
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
	expectedCost := payments.DefaultRates().CostWithMinimum(billableUsage(usage))
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
	expectedCost := payments.DefaultRates().CostWithMinimum(billableUsage(usage))
	if got := ledger.Balance(consumerID); got != initialBalance-expectedCost {
		t.Errorf("balance = %d, want %d (initial %d minus cost %d); reservation refund failed",
			got, initialBalance-expectedCost, initialBalance, expectedCost)
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
	expectedPayout := payments.ProviderPayout(payments.DefaultRates().CostWithMinimum(billableUsage(usage)))
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

	if err := st.SetModelPrice(store.ModelPrice{AccountID: accountID, Model: model, InputPrice: customInputPrice, OutputPrice: customOutputPrice}); err != nil {
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

	expectedCost := payments.Rates{Input: customInputPrice, Output: customOutputPrice}.CostWithMinimum(billableUsage(usage))
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
