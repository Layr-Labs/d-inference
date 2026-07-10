package api

// Billing integration tests for Darkbloom coordinator.
//
// These tests exercise the full billing flow end-to-end: consumer balance
// checking, inference charging, referral reward distribution, device auth
// linking, and multi-node account earnings.

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestNonStreamingCompleteObjectWithoutUsageDoesNotReturnSuccessAfterRefund(t *testing.T) {
	srv, _, ledger := billingTestServer(t)

	consumerID := testConsumerID
	initialBalance := ledger.Balance(consumerID)
	const reservedMicroUSD int64 = 25_000
	if err := ledger.Charge(consumerID, reservedMicroUSD, "reserve:"+consumerID); err != nil {
		t.Fatalf("reserve balance: %v", err)
	}

	pr := &registry.PendingRequest{
		RequestID:        "missing-usage-complete-object",
		Model:            "missing-usage-model",
		ConsumerKey:      consumerID,
		ReservedMicroUSD: reservedMicroUSD,
		ChunkCh:          make(chan string, 1),
		CompleteCh:       make(chan protocol.UsageInfo, 1),
		ErrorCh:          make(chan protocol.InferenceErrorMessage, 1),
	}
	close(pr.ChunkCh)

	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	req := httptest.NewRequest(http.MethodPost, "/v1/chat/completions", nil).WithContext(ctx)
	rr := httptest.NewRecorder()
	firstChunk := `data: {"id":"chatcmpl-missing-usage","object":"chat.completion","choices":[{"message":{"role":"assistant","content":"ok"}}]}`

	srv.handleNonStreamingResponseWithFirstChunk(rr, req, pr, []string{firstChunk})

	if rr.Code == http.StatusOK {
		t.Fatalf("status = 200 with refunded reservation and no completion usage; body = %s", rr.Body.String())
	}
	if got := ledger.Balance(consumerID); got != initialBalance {
		t.Fatalf("balance = %d, want refunded balance %d", got, initialBalance)
	}
}

func TestLinkedProviderAccountCustomPriceUsedForSettlement(t *testing.T) {
	srv, st, ledger := billingTestServer(t)

	model := "linked-provider-custom-price-model"
	accountID := "linked-provider-account"
	const customInputPrice int64 = 50_000
	const customOutputPrice int64 = 10_000_000
	if err := st.SetModelPrice(accountID, model, customInputPrice, customOutputPrice); err != nil {
		t.Fatalf("set account custom price: %v", err)
	}

	provider := srv.registry.Register("linked-provider", nil, &protocol.RegisterMessage{
		Models: []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}},
	})
	provider.Mu().Lock()
	provider.AccountID = accountID
	provider.Mu().Unlock()

	usage := protocol.UsageInfo{PromptTokens: 1000, CompletionTokens: 500}
	expectedCost := payments.CalculateCostWithOverrides(model, usage.PromptTokens, usage.CompletionTokens, customInputPrice, customOutputPrice, true)
	expectedPayout := payments.ProviderPayout(expectedCost)

	consumerID := testConsumerID
	initialBalance := ledger.Balance(consumerID)
	if err := ledger.Charge(consumerID, expectedCost, "reserve:"+consumerID); err != nil {
		t.Fatalf("reserve balance: %v", err)
	}

	pr := &registry.PendingRequest{
		RequestID:        "linked-provider-custom-price",
		Model:            model,
		ConsumerKey:      consumerID,
		ReservedMicroUSD: expectedCost,
		ChunkCh:          make(chan string, 1),
		CompleteCh:       make(chan protocol.UsageInfo, 1),
		ErrorCh:          make(chan protocol.InferenceErrorMessage, 1),
	}
	provider.AddPending(pr)

	srv.handleComplete(provider.ID, provider, &protocol.InferenceCompleteMessage{
		Type:      protocol.TypeInferenceComplete,
		RequestID: pr.RequestID,
		Usage:     usage,
	})

	if got := st.GetWithdrawableBalance(accountID); got != expectedPayout {
		t.Fatalf("provider account payout = %d, want %d", got, expectedPayout)
	}
	if got := ledger.Balance(consumerID); got != initialBalance-expectedCost {
		t.Fatalf("consumer balance = %d, want %d", got, initialBalance-expectedCost)
	}
}

// TestHandleCompleteRecordsJobSuccessOnly verifies handleComplete counts a
// successful job but does NOT itself record the latency EWMA: the responsiveness
// sample is recorded by the consumer/dispatch goroutine at commit (it owns the
// request timing), so the provider read-loop goroutine never reads that timing.
// handleComplete leaving AvgResponseTime untouched is what keeps that path
// race-free.
func TestHandleCompleteRecordsJobSuccessOnly(t *testing.T) {
	srv, _, ledger := billingTestServer(t)

	model := "job-success-model"
	provider := srv.registry.Register("job-success-provider", nil, &protocol.RegisterMessage{
		Models: []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}},
	})

	consumerID := testConsumerID
	usage := protocol.UsageInfo{PromptTokens: 100, CompletionTokens: 500}
	cost := payments.CalculateCost(model, usage.PromptTokens, usage.CompletionTokens)
	if err := ledger.Charge(consumerID, cost, "reserve:"+consumerID); err != nil {
		t.Fatalf("reserve balance: %v", err)
	}

	pr := &registry.PendingRequest{
		RequestID:        "job-success",
		Model:            model,
		ConsumerKey:      consumerID,
		ReservedMicroUSD: cost,
		ChunkCh:          make(chan string, 1),
		CompleteCh:       make(chan protocol.UsageInfo, 1),
		ErrorCh:          make(chan protocol.InferenceErrorMessage, 1),
	}
	provider.AddPending(pr)

	srv.handleComplete(provider.ID, provider, &protocol.InferenceCompleteMessage{
		Type:      protocol.TypeInferenceComplete,
		RequestID: pr.RequestID,
		Usage:     usage,
	})

	p := srv.registry.GetProvider(provider.ID)
	if p == nil {
		t.Fatal("provider missing after complete")
	}
	if p.Reputation.SuccessfulJobs != 1 {
		t.Errorf("successful_jobs = %d, want 1", p.Reputation.SuccessfulJobs)
	}
	// handleComplete must not record latency (it has no race-free access to the
	// timing); and it must never derive latency from answer length.
	if p.Reputation.AvgResponseTime != 0 {
		t.Errorf("avg_response_time = %v, want 0 (latency is recorded at dispatch commit, not handleComplete)", p.Reputation.AvgResponseTime)
	}
}

func TestRefundReservedBalanceDoesNotFinalizeWhenCreditFails(t *testing.T) {
	srv, st, _ := billingTestServer(t)
	srv.store = failingCreditStore{Store: st}

	pr := &registry.PendingRequest{
		RequestID:        "refund-credit-fails",
		Model:            "refund-credit-fails-model",
		ConsumerKey:      "test-key",
		ReservedMicroUSD: 50_000,
	}

	if ok := srv.refundReservedBalance(pr, "forced-failure"); ok {
		t.Fatal("refundReservedBalance returned true despite store credit failure")
	}
	if ok := pr.MarkReservationFinalized(); !ok {
		t.Fatal("reservation was finalized even though refund credit failed")
	}
}

// TestReportedCostCannotExceedFundedReservation verifies that provider-reported
// usage can never create a post-generation debit or payout above the durable
// pre-start funding bound.
func TestReportedCostCannotExceedFundedReservation(t *testing.T) {
	srv, st, ledger := billingTestServer(t)

	model := "overage-test-model"
	accountID := "overage-provider-account"
	// Set a provider custom price well above the platform default so that
	// the actual cost computed by handleComplete exceeds ReservedMicroUSD.
	const customInputPrice int64 = 500_000     // 10x platform default
	const customOutputPrice int64 = 50_000_000 // 10x platform default
	if err := st.SetModelPrice(accountID, model, customInputPrice, customOutputPrice); err != nil {
		t.Fatalf("set provider custom price: %v", err)
	}

	provider := srv.registry.Register("overage-provider", nil, &protocol.RegisterMessage{
		Models: []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}},
	})
	provider.Mu().Lock()
	provider.AccountID = accountID
	provider.Mu().Unlock()

	usage := protocol.UsageInfo{PromptTokens: 1000, CompletionTokens: 500}
	actualCost := payments.CalculateCostWithOverrides(model, usage.PromptTokens, usage.CompletionTokens, customInputPrice, customOutputPrice, true)
	// Reservation is deliberately lower than actual cost to trigger overage.
	reservedAmount := actualCost / 2

	consumerID := testConsumerID
	initialBalance := ledger.Balance(consumerID)
	if err := ledger.Charge(consumerID, reservedAmount, "reserve:"+consumerID); err != nil {
		t.Fatalf("reserve balance: %v", err)
	}

	pr := &registry.PendingRequest{
		RequestID:        "overage-charge-test",
		Model:            model,
		ConsumerKey:      consumerID,
		ReservedMicroUSD: reservedAmount,
		ChunkCh:          make(chan string, 1),
		CompleteCh:       make(chan protocol.UsageInfo, 1),
		ErrorCh:          make(chan protocol.InferenceErrorMessage, 1),
	}
	provider.AddPending(pr)

	srv.handleComplete(provider.ID, provider, &protocol.InferenceCompleteMessage{
		Type:      protocol.TypeInferenceComplete,
		RequestID: pr.RequestID,
		Usage:     usage,
	})

	expectedPayout := payments.ProviderPayout(reservedAmount)
	if got := st.GetWithdrawableBalance(accountID); got != expectedPayout {
		t.Errorf("provider payout = %d, want funded cap %d", got, expectedPayout)
	}
	if got := ledger.Balance(consumerID); got != initialBalance-reservedAmount {
		t.Errorf("consumer balance = %d, want funded cap %d", got, initialBalance-reservedAmount)
	}
}

// TestOverageChargeClampOnInsufficientBalance verifies that when the overage
// charge fails (consumer balance drained mid-flight), the coordinator falls
// back to the hard clamp at the reservation amount.
func TestOverageChargeClampOnInsufficientBalance(t *testing.T) {
	srv, st, _ := billingTestServer(t)

	model := "overage-clamp-model"
	accountID := "overage-clamp-account"
	const customInputPrice int64 = 500_000
	const customOutputPrice int64 = 50_000_000
	if err := st.SetModelPrice(accountID, model, customInputPrice, customOutputPrice); err != nil {
		t.Fatalf("set provider custom price: %v", err)
	}

	provider := srv.registry.Register("overage-clamp-provider", nil, &protocol.RegisterMessage{
		Models: []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}},
	})
	provider.Mu().Lock()
	provider.AccountID = accountID
	provider.Mu().Unlock()

	usage := protocol.UsageInfo{PromptTokens: 1000, CompletionTokens: 500}
	actualCost := payments.CalculateCostWithOverrides(model, usage.PromptTokens, usage.CompletionTokens, customInputPrice, customOutputPrice, true)
	reservedAmount := actualCost / 2

	// Use a consumer with exactly the reserved amount so the overage charge
	// will fail due to insufficient balance.
	consumerID := "low-balance-consumer"
	_ = st.Credit(consumerID, reservedAmount, store.LedgerDeposit, "test-setup")
	if err := srv.ledger.Charge(consumerID, reservedAmount, "reserve:"+consumerID); err != nil {
		t.Fatalf("reserve balance: %v", err)
	}

	pr := &registry.PendingRequest{
		RequestID:        "overage-clamp-test",
		Model:            model,
		ConsumerKey:      consumerID,
		ReservedMicroUSD: reservedAmount,
		ChunkCh:          make(chan string, 1),
		CompleteCh:       make(chan protocol.UsageInfo, 1),
		ErrorCh:          make(chan protocol.InferenceErrorMessage, 1),
	}
	provider.AddPending(pr)

	srv.handleComplete(provider.ID, provider, &protocol.InferenceCompleteMessage{
		Type:      protocol.TypeInferenceComplete,
		RequestID: pr.RequestID,
		Usage:     usage,
	})

	// Overage charge should have failed, so the provider gets paid based on
	// the clamped reservation amount, not the full actual cost.
	expectedPayout := payments.ProviderPayout(reservedAmount)
	if got := st.GetWithdrawableBalance(accountID); got != expectedPayout {
		t.Errorf("provider payout = %d, want %d (clamped to reservation)", got, expectedPayout)
	}
	// Consumer balance should be zero: entire deposit was reserved, overage
	// failed, no refund since totalCost was clamped to exactly the reservation.
	if got := srv.ledger.Balance(consumerID); got != 0 {
		t.Errorf("consumer balance = %d, want 0", got)
	}
}
