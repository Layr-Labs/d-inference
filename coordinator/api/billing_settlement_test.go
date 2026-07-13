package api

// Billing integration tests for Darkbloom coordinator.
//
// These tests exercise the full billing flow end-to-end: consumer balance
// checking, inference charging, referral reward distribution, device auth
// linking, and multi-node account earnings.

import (
	"context"
	"errors"
	"math"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func assertPendingResponseClosed(t *testing.T, pending *registry.PendingRequest) {
	t.Helper()
	if _, ok := <-pending.ChunkCh; ok {
		t.Fatal("chunk channel remained open after terminal error")
	}
	if _, ok := <-pending.CompleteCh; ok {
		t.Fatal("completion channel remained open after terminal error")
	}
	if _, ok := <-pending.ErrorCh; ok {
		t.Fatal("error channel remained open after terminal error")
	}
}

type flakyInferenceSettlementStore struct {
	store.Store
	mu        sync.Mutex
	remaining int
	attempts  int
}

type ambiguousInferenceSettlementStore struct {
	store.Store
	mu       sync.Mutex
	injected bool
	attempts int
}

func reserveSettlementTestBalance(
	t *testing.T,
	storeBackend store.Store,
	accountID string,
	amount int64,
	reservationID string,
) int64 {
	t.Helper()
	reservedWithdrawable, _, err := storeBackend.ReserveInferenceBalance(
		accountID, amount, reservationID,
	)
	if err != nil {
		t.Fatal(err)
	}
	return reservedWithdrawable
}

func (s *ambiguousInferenceSettlementStore) SettleInference(settlement *store.InferenceSettlement) (store.InferenceSettlementDisposition, error) {
	s.mu.Lock()
	s.attempts++
	inject := !s.injected
	if inject {
		s.injected = true
	}
	s.mu.Unlock()
	disposition, err := s.Store.SettleInference(settlement)
	if inject && err == nil {
		return "", errors.New("ambiguous commit result")
	}
	return disposition, err
}

func (s *ambiguousInferenceSettlementStore) Attempts() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.attempts
}

func (s *flakyInferenceSettlementStore) SettleInference(settlement *store.InferenceSettlement) (store.InferenceSettlementDisposition, error) {
	s.mu.Lock()
	s.attempts++
	if s.remaining > 0 {
		s.remaining--
		s.mu.Unlock()
		return "", errors.New("transient settlement failure")
	}
	s.mu.Unlock()
	return s.Store.SettleInference(settlement)
}

func (s *flakyInferenceSettlementStore) Attempts() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.attempts
}

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
	reservedWithdrawable := reserveSettlementTestBalance(
		t, st, consumerID, expectedCost, "linked-provider-custom-price",
	)

	pr := &registry.PendingRequest{
		RequestID:                        "linked-provider-custom-price",
		ReservationID:                    "linked-provider-custom-price",
		Model:                            model,
		ConsumerKey:                      consumerID,
		ReservedMicroUSD:                 expectedCost,
		ReservedWithdrawableMicroUSD:     reservedWithdrawable,
		BaseReservedMicroUSD:             expectedCost,
		BaseReservedWithdrawableMicroUSD: reservedWithdrawable,
		ChunkCh:                          make(chan string, 1),
		CompleteCh:                       make(chan protocol.UsageInfo, 1),
		ErrorCh:                          make(chan protocol.InferenceErrorMessage, 1),
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
	srv, st, _ := billingTestServer(t)

	model := "job-success-model"
	provider := srv.registry.Register("job-success-provider", nil, &protocol.RegisterMessage{
		Models: []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}},
	})

	consumerID := testConsumerID
	usage := protocol.UsageInfo{PromptTokens: 100, CompletionTokens: 500}
	cost := payments.CalculateCost(model, usage.PromptTokens, usage.CompletionTokens)
	reservedWithdrawable := reserveSettlementTestBalance(
		t, st, consumerID, cost, "job-success",
	)

	pr := &registry.PendingRequest{
		RequestID:                        "job-success",
		ReservationID:                    "job-success",
		Model:                            model,
		ConsumerKey:                      consumerID,
		ReservedMicroUSD:                 cost,
		ReservedWithdrawableMicroUSD:     reservedWithdrawable,
		BaseReservedMicroUSD:             cost,
		BaseReservedWithdrawableMicroUSD: reservedWithdrawable,
		ChunkCh:                          make(chan string, 1),
		CompleteCh:                       make(chan protocol.UsageInfo, 1),
		ErrorCh:                          make(chan protocol.InferenceErrorMessage, 1),
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

func TestCompletionRetriesAtomicSettlementWithoutPartialProjection(t *testing.T) {
	srv, st, ledger := billingTestServer(t)
	flaky := &flakyInferenceSettlementStore{Store: st, remaining: 2}
	srv.store = flaky
	const (
		model         = "retry-settlement-model"
		reservationID = "retry-settlement-reservation"
		reserved      = int64(500)
	)
	initialBalance := ledger.Balance(testConsumerID)
	reservedWithdrawable, _, err := st.ReserveInferenceBalance(
		testConsumerID, reserved, reservationID,
	)
	if err != nil {
		t.Fatal(err)
	}
	provider := srv.registry.Register("retry-settlement-provider", nil, &protocol.RegisterMessage{
		Models: []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}},
	})
	provider.Mu().Lock()
	provider.AccountID = "retry-settlement-provider-account"
	provider.Mu().Unlock()
	pr := &registry.PendingRequest{
		RequestID: "retry-settlement-attempt", ReservationID: reservationID,
		Model: model, ConsumerKey: testConsumerID,
		ReservedMicroUSD: reserved, ReservedWithdrawableMicroUSD: reservedWithdrawable,
		BaseReservedMicroUSD: reserved, BaseReservedWithdrawableMicroUSD: reservedWithdrawable,
		ChunkCh: make(chan string, 1), CompleteCh: make(chan protocol.UsageInfo, 1),
		ErrorCh: make(chan protocol.InferenceErrorMessage, 1),
	}
	provider.AddPending(pr)
	usage := protocol.UsageInfo{PromptTokens: 1000, CompletionTokens: 1000}
	srv.handleComplete(provider.ID, provider, &protocol.InferenceCompleteMessage{
		Type: protocol.TypeInferenceComplete, RequestID: pr.RequestID, Usage: usage,
	})
	if flaky.Attempts() != settlementRetryAttempts {
		t.Fatalf("settlement attempts = %d, want %d", flaky.Attempts(), settlementRetryAttempts)
	}
	if balance := ledger.Balance(testConsumerID); balance != initialBalance-250 {
		t.Fatalf("consumer balance = %d, want %d", balance, initialBalance-250)
	}
	if payout := st.GetWithdrawableBalance("retry-settlement-provider-account"); payout != 250 {
		t.Fatalf("provider payout = %d, want 250", payout)
	}
	if usageRows := st.UsageByConsumer(testConsumerID); len(usageRows) != 1 {
		t.Fatalf("usage rows = %d, want 1", len(usageRows))
	}
}

func TestAmbiguousSettlementCommitResolvesDurableReplay(t *testing.T) {
	srv, backing := newReservationTestServer(t, ServerConfig{}, nil)
	createServiceUser(t, backing, "svc-ambiguous")
	if err := backing.Credit("svc-ambiguous", 1_000_000, store.LedgerDeposit, "seed"); err != nil {
		t.Fatal(err)
	}
	const hold int64 = 500_000
	serviceMode, reservedWithdrawable, err := srv.reserveInitialBalance(
		"svc-ambiguous", "ambiguous-model", hold, "reserve-ambiguous",
	)
	if err != nil || serviceMode {
		t.Fatalf("reserve service=%t err=%v", serviceMode, err)
	}
	ambiguous := &ambiguousInferenceSettlementStore{Store: backing}
	srv.store = ambiguous
	provider := srv.registry.Register("ambiguous-provider", nil, &protocol.RegisterMessage{
		Models: []protocol.ModelInfo{{ID: "ambiguous-model", ModelType: "chat", Quantization: "4bit"}},
	})
	pr := &registry.PendingRequest{
		RequestID: "ambiguous-attempt", ReservationID: "reserve-ambiguous",
		Model: "ambiguous-model", ConsumerKey: "svc-ambiguous",
		ReservedMicroUSD: hold, ReservedWithdrawableMicroUSD: reservedWithdrawable,
		BaseReservedMicroUSD: hold, BaseReservedWithdrawableMicroUSD: reservedWithdrawable,
		ChunkCh: make(chan string, 1), CompleteCh: make(chan protocol.UsageInfo, 1),
		ErrorCh: make(chan protocol.InferenceErrorMessage, 1),
	}
	provider.AddPending(pr)
	srv.handleComplete(provider.ID, provider, &protocol.InferenceCompleteMessage{
		Type: protocol.TypeInferenceComplete, RequestID: pr.RequestID,
		Usage: protocol.UsageInfo{PromptTokens: 1000, CompletionTokens: 1000},
	})
	if ambiguous.Attempts() != 2 {
		t.Fatalf("settlement attempts = %d, want applied+replay", ambiguous.Attempts())
	}
	select {
	case <-pr.CompleteCh:
	default:
		t.Fatal("committed replay did not signal completion")
	}
	if balance := backing.GetBalance("svc-ambiguous"); balance != 999_750 {
		t.Fatalf("ambiguous replay balance = %d, want 999750", balance)
	}
}

func TestCompletionSettlementFailureDoesNotSignalSuccessOrMoveBeneficiaryMoney(t *testing.T) {
	srv, st, ledger := billingTestServer(t)
	srv.store = failingCreditStore{Store: st}
	const (
		model         = "failed-settlement-model"
		reservationID = "failed-settlement-reservation"
		reserved      = int64(500)
	)
	initialBalance := ledger.Balance(testConsumerID)
	reservedWithdrawable, _, err := st.ReserveInferenceBalance(
		testConsumerID, reserved, reservationID,
	)
	if err != nil {
		t.Fatal(err)
	}
	provider := srv.registry.Register("failed-settlement-provider", nil, &protocol.RegisterMessage{
		Models: []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}},
	})
	provider.Mu().Lock()
	provider.AccountID = "failed-settlement-provider-account"
	provider.Mu().Unlock()
	pr := &registry.PendingRequest{
		RequestID: "failed-settlement-attempt", ReservationID: reservationID,
		Model: model, ConsumerKey: testConsumerID,
		ReservedMicroUSD: reserved, ReservedWithdrawableMicroUSD: reservedWithdrawable,
		BaseReservedMicroUSD: reserved, BaseReservedWithdrawableMicroUSD: reservedWithdrawable,
		ChunkCh: make(chan string, 1), CompleteCh: make(chan protocol.UsageInfo, 1),
		ErrorCh: make(chan protocol.InferenceErrorMessage, 1),
	}
	provider.AddPending(pr)
	srv.handleComplete(provider.ID, provider, &protocol.InferenceCompleteMessage{
		Type: protocol.TypeInferenceComplete, RequestID: pr.RequestID,
		Usage: protocol.UsageInfo{PromptTokens: 1000, CompletionTokens: 1000},
	})
	select {
	case completion, ok := <-pr.CompleteCh:
		if ok {
			t.Fatalf("failed settlement signaled successful completion: %+v", completion)
		}
	default:
		t.Fatal("failed settlement left completion channel open")
	}
	select {
	case terminal := <-pr.ErrorCh:
		if terminal.StatusCode != http.StatusServiceUnavailable ||
			terminal.ErrorReason != "settlement_pending" {
			t.Fatalf("settlement failure terminal = %+v", terminal)
		}
	default:
		t.Fatal("failed settlement did not signal a retryable error")
	}
	assertPendingResponseClosed(t, pr)
	if balance := ledger.Balance(testConsumerID); balance != initialBalance-reserved {
		t.Fatalf("failed settlement changed held consumer balance to %d", balance)
	}
	if payout := st.GetWithdrawableBalance("failed-settlement-provider-account"); payout != 0 {
		t.Fatalf("failed settlement paid provider %d", payout)
	}
	if !pr.IsReservationFinalized() {
		t.Fatal("durable review did not fence the local reservation")
	}
}

func TestInvalidProviderUsageReleasesReservationWithoutPayout(t *testing.T) {
	srv, st, ledger := billingTestServer(t)
	const (
		model         = "invalid-usage-model"
		reservationID = "invalid-usage-reservation"
		reserved      = int64(500)
	)
	initialBalance := ledger.Balance(testConsumerID)
	reservedWithdrawable, _, err := st.ReserveInferenceBalance(
		testConsumerID, reserved, reservationID,
	)
	if err != nil {
		t.Fatal(err)
	}
	provider := srv.registry.Register("invalid-usage-provider", nil, &protocol.RegisterMessage{
		Models: []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}},
	})
	provider.Mu().Lock()
	provider.AccountID = "invalid-usage-provider-account"
	provider.Mu().Unlock()
	pr := &registry.PendingRequest{
		RequestID: "invalid-usage-attempt", ReservationID: reservationID,
		Model: model, ConsumerKey: testConsumerID, RequestedMaxTokens: 100,
		ReservedMicroUSD: reserved, ReservedWithdrawableMicroUSD: reservedWithdrawable,
		BaseReservedMicroUSD: reserved, BaseReservedWithdrawableMicroUSD: reservedWithdrawable,
		ChunkCh: make(chan string, 1), CompleteCh: make(chan protocol.UsageInfo, 1),
		ErrorCh: make(chan protocol.InferenceErrorMessage, 1),
	}
	provider.AddPending(pr)
	srv.handleComplete(provider.ID, provider, &protocol.InferenceCompleteMessage{
		Type: protocol.TypeInferenceComplete, RequestID: pr.RequestID,
		Usage: protocol.UsageInfo{PromptTokens: int(math.MaxInt32) + 1, CompletionTokens: 10},
	})
	if balance := ledger.Balance(testConsumerID); balance != initialBalance {
		t.Fatalf("invalid usage left consumer charged: balance=%d want=%d", balance, initialBalance)
	}
	if payout := st.GetWithdrawableBalance("invalid-usage-provider-account"); payout != 0 {
		t.Fatalf("invalid usage paid provider %d", payout)
	}
	select {
	case terminal := <-pr.ErrorCh:
		if terminal.ErrorReason != "invalid_provider_usage" {
			t.Fatalf("terminal = %+v", terminal)
		}
	default:
		t.Fatal("invalid usage did not produce error terminal")
	}
	assertPendingResponseClosed(t, pr)
}

func TestBoundedProviderUsageCapsPlainRequestPromptEstimate(t *testing.T) {
	pending := &registry.PendingRequest{
		EstimatedPromptTokens: 100,
		RequestedMaxTokens:    50,
	}
	usage, invalid, capped := boundedProviderUsage(pending, protocol.UsageInfo{
		PromptTokens:     2_000,
		CompletionTokens: 40,
		ReasoningTokens:  20,
	})
	if invalid || !capped {
		t.Fatalf("bounded usage = %+v invalid=%t capped=%t", usage, invalid, capped)
	}
	if usage.PromptTokens != 1_024 {
		t.Fatalf("prompt tokens = %d, want conservative cap 1024", usage.PromptTokens)
	}

	unknownEstimate := &registry.PendingRequest{RequestedMaxTokens: 50}
	usage, invalid, capped = boundedProviderUsage(unknownEstimate, protocol.UsageInfo{
		PromptTokens:     2_000,
		CompletionTokens: 40,
	})
	if invalid || capped || usage.PromptTokens != 2_000 {
		t.Fatalf("unknown estimate was capped: %+v invalid=%t capped=%t", usage, invalid, capped)
	}
}

func TestProviderCompletionUsageIsCappedAtFundedOutputBound(t *testing.T) {
	srv, st, ledger := billingTestServer(t)
	const (
		model         = "capped-usage-model"
		reservationID = "capped-usage-reservation"
		reserved      = int64(500)
	)
	initialBalance := ledger.Balance(testConsumerID)
	reservedWithdrawable, _, err := st.ReserveInferenceBalance(
		testConsumerID, reserved, reservationID,
	)
	if err != nil {
		t.Fatal(err)
	}
	provider := srv.registry.Register("capped-usage-provider", nil, &protocol.RegisterMessage{
		Models: []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}},
	})
	provider.Mu().Lock()
	provider.AccountID = "capped-usage-provider-account"
	provider.Mu().Unlock()
	pr := &registry.PendingRequest{
		RequestID: "capped-usage-attempt", ReservationID: reservationID,
		Model: model, ConsumerKey: testConsumerID, RequestedMaxTokens: 10,
		ReservedMicroUSD: reserved, ReservedWithdrawableMicroUSD: reservedWithdrawable,
		BaseReservedMicroUSD: reserved, BaseReservedWithdrawableMicroUSD: reservedWithdrawable,
		ChunkCh: make(chan string, 1), CompleteCh: make(chan protocol.UsageInfo, 1),
		ErrorCh: make(chan protocol.InferenceErrorMessage, 1),
	}
	provider.AddPending(pr)
	srv.handleComplete(provider.ID, provider, &protocol.InferenceCompleteMessage{
		Type: protocol.TypeInferenceComplete, RequestID: pr.RequestID,
		Usage: protocol.UsageInfo{PromptTokens: 1000, CompletionTokens: 100},
	})
	expectedCost := payments.CalculateCost(model, 1000, 10)
	if balance := ledger.Balance(testConsumerID); balance != initialBalance-expectedCost {
		t.Fatalf("consumer balance = %d, want %d", balance, initialBalance-expectedCost)
	}
	rows := st.UsageByConsumer(testConsumerID)
	if len(rows) != 1 || rows[0].CompletionTokens != 10 {
		t.Fatalf("capped usage rows = %+v", rows)
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
	reservedWithdrawable := reserveSettlementTestBalance(
		t, st, consumerID, reservedAmount, "overage-charge-test",
	)

	pr := &registry.PendingRequest{
		RequestID:                        "overage-charge-test",
		ReservationID:                    "overage-charge-test",
		Model:                            model,
		ConsumerKey:                      consumerID,
		ReservedMicroUSD:                 reservedAmount,
		ReservedWithdrawableMicroUSD:     reservedWithdrawable,
		BaseReservedMicroUSD:             reservedAmount,
		BaseReservedWithdrawableMicroUSD: reservedWithdrawable,
		ChunkCh:                          make(chan string, 1),
		CompleteCh:                       make(chan protocol.UsageInfo, 1),
		ErrorCh:                          make(chan protocol.InferenceErrorMessage, 1),
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
	reservedWithdrawable := reserveSettlementTestBalance(
		t, st, consumerID, reservedAmount, "overage-clamp-test",
	)

	pr := &registry.PendingRequest{
		RequestID:                        "overage-clamp-test",
		ReservationID:                    "overage-clamp-test",
		Model:                            model,
		ConsumerKey:                      consumerID,
		ReservedMicroUSD:                 reservedAmount,
		ReservedWithdrawableMicroUSD:     reservedWithdrawable,
		BaseReservedMicroUSD:             reservedAmount,
		BaseReservedWithdrawableMicroUSD: reservedWithdrawable,
		ChunkCh:                          make(chan string, 1),
		CompleteCh:                       make(chan protocol.UsageInfo, 1),
		ErrorCh:                          make(chan protocol.InferenceErrorMessage, 1),
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
