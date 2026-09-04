package api

// Settlement ordering (T12-04): the consumer is released as soon as ITS
// balance is final, and the provider's slot is freed right after
// RemovePending — the provider credit and platform fee are provider-side
// rows that land after the consumer's [DONE]. These tests pin that ordering
// with a store whose CreditProviderAccount is slow, and pin that the
// finalize gate (exactly one settle/refund winner, one payout) is unchanged.

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"log/slog"

	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"nhooyr.io/websocket"
)

// delayedCreditStore delays CreditProviderAccount — the provider-side
// settlement write — by delay, standing in for an in-VPC round trip under
// DB pressure. Everything else delegates to the real memory store.
type delayedCreditStore struct {
	store.Store
	delay   time.Duration
	credits atomic.Int64
}

func (d *delayedCreditStore) CreditProviderAccount(e *store.ProviderEarning) error {
	time.Sleep(d.delay)
	d.credits.Add(1)
	return d.Store.CreditProviderAccount(e)
}

// delayedBillingServer is billingTestServer with the delayed store wrapped
// around the memory store; the inner store is returned for assertions.
func delayedBillingServer(t *testing.T, delay time.Duration) (*Server, *store.MemoryStore, *delayedCreditStore, *payments.Ledger) {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	inner := store.NewMemory(store.Config{AdminKey: "test-key"})
	slow := &delayedCreditStore{Store: inner, delay: delay}
	reg := registry.New(logger)
	srv := NewServer(reg, slow, ServerConfig{}, logger)
	srv.challengeInterval = 200 * time.Millisecond
	ledger := srv.ledger
	srv.SetBilling(billing.NewService(slow, ledger, logger, billing.Config{MockMode: true, ReferralSharePercent: 20}))
	_ = inner.Credit(testConsumerID, 100_000_000, store.LedgerDeposit, "test-setup")
	return srv, inner, slow, ledger
}

// serveOneInferenceStamped is serveOneInference that also reports the instant
// the provider wrote its complete frame, so the test can measure how long the
// consumer waited for [DONE] after the terminal.
func serveOneInferenceStamped(ctx context.Context, t *testing.T, conn *websocket.Conn, pubKey string, usage protocol.UsageInfo) <-chan time.Time {
	t.Helper()
	sent := make(chan time.Time, 1)
	go func() {
		defer close(sent)
		for {
			_, data, err := conn.Read(ctx)
			if err != nil {
				return
			}
			var env struct {
				Type string `json:"type"`
			}
			_ = json.Unmarshal(data, &env)
			switch env.Type {
			case protocol.TypeAttestationChallenge:
				_ = conn.Write(ctx, websocket.MessageText, makeValidChallengeResponse(data, pubKey))
			case protocol.TypeInferenceRequest:
				var req protocol.InferenceRequestMessage
				_ = json.Unmarshal(data, &req)
				writeEncryptedTestChunk(t, ctx, conn, req, pubKey,
					`data: {"id":"chatcmpl-1","choices":[{"delta":{"content":"ok"}}]}`+"\n\n")
				complete, _ := json.Marshal(protocol.InferenceCompleteMessage{
					Type: protocol.TypeInferenceComplete, RequestID: req.RequestID, Usage: usage,
				})
				_ = conn.Write(ctx, websocket.MessageText, complete)
				sent <- time.Now()
				return
			}
		}
	}()
	return sent
}

// TestSettlementConsumerReleasedBeforeProviderCredit: with the provider
// credit delayed 1 s, the consumer's [DONE] arrives well inside that delay,
// and the earning row still lands afterwards. Before the reorder the
// consumer waited for the credit (settlementWg.Wait preceded the signal).
func TestSettlementConsumerReleasedBeforeProviderCredit(t *testing.T) {
	const creditDelay = time.Second
	srv, inner, slow, _ := delayedBillingServer(t, creditDelay)
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	model := "slow-credit-model"
	conn, providerID, pubKey := setupProviderForBilling(t, ctx, ts, srv.registry, model)
	defer conn.Close(websocket.StatusNormalClosure, "")
	accountID := "test-account-" + providerID
	usage := protocol.UsageInfo{PromptTokens: 100, CompletionTokens: 50}
	expectedPayout := payments.ProviderPayout(payments.CalculateCost(model, usage.PromptTokens, usage.CompletionTokens))

	sent := serveOneInferenceStamped(ctx, t, conn, pubKey, usage)
	body := `{"model":"` + model + `","messages":[{"role":"user","content":"hello"}],"stream":true}`
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, ts.URL+"/v1/chat/completions", strings.NewReader(body))
	req.Header.Set("Authorization", "Bearer test-key")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("request: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d, want 200", resp.StatusCode)
	}
	var doneAt time.Time
	sawDone := false
	scanner := bufio.NewScanner(resp.Body)
	for scanner.Scan() {
		if strings.HasPrefix(scanner.Text(), "data: [DONE]") {
			doneAt = time.Now()
			sawDone = true
		}
	}
	if !sawDone {
		t.Fatal("stream ended without [DONE]")
	}
	completeAt := <-sent
	waited := doneAt.Sub(completeAt)
	if waited >= creditDelay/2 {
		t.Fatalf("consumer waited %v for [DONE] after the terminal; the %v provider credit must not be on that path", waited, creditDelay)
	}
	if slow.credits.Load() != 0 {
		t.Fatalf("provider credit completed before [DONE] (%d credits) — the delay was not on the settlement path", slow.credits.Load())
	}
	// The provider is still paid, just after the consumer's response.
	if !waitForCond(3*time.Second, func() bool { return inner.GetWithdrawableBalance(accountID) == expectedPayout }) {
		t.Fatalf("provider payout = %d, want %d after the delayed credit", inner.GetWithdrawableBalance(accountID), expectedPayout)
	}
	if slow.credits.Load() != 1 {
		t.Fatalf("CreditProviderAccount calls = %d, want 1", slow.credits.Load())
	}
}

// pendingForSettlement builds a consumer-present pending request holding a
// reservation of reserved micro-USD.
func pendingForSettlement(requestID, model string, reserved int64) *registry.PendingRequest {
	return &registry.PendingRequest{
		RequestID:        requestID,
		Model:            model,
		ConsumerKey:      testConsumerID,
		ReservedMicroUSD: reserved,
		ChunkCh:          make(chan registry.ProviderChunk, 1),
		CompleteCh:       make(chan protocol.UsageInfo, 1),
		ErrorCh:          make(chan protocol.InferenceErrorMessage, 1),
	}
}

func registerSettlementProvider(t *testing.T, srv *Server, id, model, accountID string) *registry.Provider {
	t.Helper()
	provider := srv.registry.Register(id, nil, &protocol.RegisterMessage{
		Models: []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}},
	})
	provider.Mu().Lock()
	provider.AccountID = accountID
	provider.Mu().Unlock()
	srv.registry.SetTrustLevel(id, registry.TrustHardware)
	srv.registry.RecordChallengeSuccess(id)
	return provider
}

// TestSettlementQueuedRequestDrainsBeforeProviderCredit: a saturated provider
// completes one request; the queued request waiting for that slot must be
// assigned before the (1 s) provider credit completes. Before the reorder
// SetProviderIdle — the queue drain — ran after settlementWg.Wait.
func TestSettlementQueuedRequestDrainsBeforeProviderCredit(t *testing.T) {
	const creditDelay = time.Second
	srv, inner, _, ledger := delayedBillingServer(t, creditDelay)
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	model := "queue-drain-model"
	conn, providerID, _ := setupProviderForBilling(t, ctx, ts, srv.registry, model)
	defer conn.Close(websocket.StatusNormalClosure, "")
	provider := srv.registry.GetProvider(providerID)
	accountID := "test-account-" + providerID
	if findRoutableProvider(srv.registry, model) == nil {
		t.Fatal("provider should be routable before it is filled")
	}

	// Fill all but one slot with idle fillers; the real request takes the last.
	for i := 0; i < registry.DefaultMaxConcurrent-1; i++ {
		provider.AddPending(&registry.PendingRequest{RequestID: fmt.Sprintf("filler-%d", i), ProviderID: provider.ID, Model: model})
	}
	usage := protocol.UsageInfo{PromptTokens: 100, CompletionTokens: 50}
	cost := payments.CalculateCost(model, usage.PromptTokens, usage.CompletionTokens)
	if err := ledger.Charge(testConsumerID, cost*2, "reserve:queue-drain"); err != nil {
		t.Fatalf("reserve: %v", err)
	}
	pr := pendingForSettlement("queue-drain-req", model, cost*2)
	provider.AddPending(pr)
	if found := findRoutableProvider(srv.registry, model); found != nil {
		t.Fatal("provider at max concurrency should not be routable")
	}
	queued := &registry.QueuedRequest{RequestID: "queued-behind", Model: model, ResponseCh: make(chan *registry.Provider, 1)}
	if err := srv.registry.Queue().Enqueue(queued); err != nil {
		t.Fatalf("enqueue: %v", err)
	}

	start := time.Now()
	completed := make(chan struct{})
	go func() {
		defer close(completed)
		srv.handleComplete(provider.ID, provider, &protocol.InferenceCompleteMessage{
			Type: protocol.TypeInferenceComplete, RequestID: pr.RequestID, Usage: usage,
		})
	}()
	select {
	case assigned := <-queued.ResponseCh:
		if assigned == nil || assigned.ID != provider.ID {
			t.Fatalf("queued request assigned %v, want %s", assigned, provider.ID)
		}
		if waited := time.Since(start); waited >= creditDelay/2 {
			t.Fatalf("queued request drained after %v; the slot must be freed before the %v provider credit", waited, creditDelay)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("queued request was never drained")
	}
	select {
	case <-completed:
		t.Fatal("handleComplete returned before the delayed credit — the drain must have run inside it")
	default:
	}
	<-completed
	if got := inner.GetWithdrawableBalance(accountID); got != payments.ProviderPayout(cost) {
		t.Fatalf("provider payout = %d, want %d", got, payments.ProviderPayout(cost))
	}
}

// TestSettlementRefundRaceExactlyOneWinner: a consumer-side refund (the
// post-terminal sweep's action) races the provider terminal on the same
// reservation. Exactly one wins the finalize gate: either the consumer is
// refunded in full and the provider is not paid, or the consumer is charged
// the cost and the provider is paid once. Never both, never neither.
func TestSettlementRefundRaceExactlyOneWinner(t *testing.T) {
	srv, inner, slow, ledger := delayedBillingServer(t, 20*time.Millisecond)
	model := "refund-race-model"
	accountID := "refund-race-account"
	provider := registerSettlementProvider(t, srv, "refund-race-provider", model, accountID)
	usage := protocol.UsageInfo{PromptTokens: 100, CompletionTokens: 50}
	cost := payments.CalculateCost(model, usage.PromptTokens, usage.CompletionTokens)
	payout := payments.ProviderPayout(cost)

	settled, refunded := 0, 0
	for i := 0; i < 24; i++ {
		before := ledger.Balance(testConsumerID)
		reserved := cost * 3
		if err := ledger.Charge(testConsumerID, reserved, fmt.Sprintf("reserve:%d", i)); err != nil {
			t.Fatalf("reserve: %v", err)
		}
		pr := pendingForSettlement(fmt.Sprintf("race-%d", i), model, reserved)
		provider.AddPending(pr)
		paidBefore := inner.GetWithdrawableBalance(accountID)

		var wg sync.WaitGroup
		wg.Add(2)
		go func() {
			defer wg.Done()
			srv.handleComplete(provider.ID, provider, &protocol.InferenceCompleteMessage{
				Type: protocol.TypeInferenceComplete, RequestID: pr.RequestID, Usage: usage,
			})
		}()
		go func() {
			defer wg.Done()
			if i%2 == 0 {
				time.Sleep(time.Millisecond)
			}
			srv.refundReservedBalance(pr, "post_terminal_sweep:"+pr.RequestID)
		}()
		wg.Wait()
		provider.RemovePending(pr.RequestID)

		after := ledger.Balance(testConsumerID)
		paid := inner.GetWithdrawableBalance(accountID) - paidBefore
		switch {
		case after == before && paid == 0:
			refunded++
		case after == before-cost && paid == payout:
			settled++
		default:
			t.Fatalf("iteration %d: consumer delta %d, provider paid %d — want (0, 0) or (-%d, %d)", i, after-before, paid, cost, payout)
		}
	}
	if settled+refunded != 24 {
		t.Fatalf("settled=%d refunded=%d", settled, refunded)
	}
	if int(slow.credits.Load()) != settled {
		t.Fatalf("CreditProviderAccount calls = %d, want %d (one per settled iteration)", slow.credits.Load(), settled)
	}
}

// TestSettlementDuplicateTerminalPaysOnce: two concurrent completions for
// one request pay the provider once and charge the consumer once.
func TestSettlementDuplicateTerminalPaysOnce(t *testing.T) {
	srv, inner, slow, ledger := delayedBillingServer(t, 100*time.Millisecond)
	model := "dup-terminal-model"
	accountID := "dup-terminal-account"
	provider := registerSettlementProvider(t, srv, "dup-terminal-provider", model, accountID)
	usage := protocol.UsageInfo{PromptTokens: 100, CompletionTokens: 50}
	cost := payments.CalculateCost(model, usage.PromptTokens, usage.CompletionTokens)
	before := ledger.Balance(testConsumerID)
	if err := ledger.Charge(testConsumerID, cost*2, "reserve:dup"); err != nil {
		t.Fatalf("reserve: %v", err)
	}
	pr := pendingForSettlement("dup-terminal", model, cost*2)
	provider.AddPending(pr)

	var wg sync.WaitGroup
	for i := 0; i < 2; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			srv.handleComplete(provider.ID, provider, &protocol.InferenceCompleteMessage{
				Type: protocol.TypeInferenceComplete, RequestID: pr.RequestID, Usage: usage,
			})
		}()
	}
	wg.Wait()
	if got := ledger.Balance(testConsumerID); got != before-cost {
		t.Fatalf("consumer balance = %d, want %d (charged once)", got, before-cost)
	}
	if got := inner.GetWithdrawableBalance(accountID); got != payments.ProviderPayout(cost) {
		t.Fatalf("provider payout = %d, want %d (paid once)", got, payments.ProviderPayout(cost))
	}
	if slow.credits.Load() != 1 {
		t.Fatalf("CreditProviderAccount calls = %d, want 1", slow.credits.Load())
	}
}

// TestSettleDBUSCoversProviderCredit: the profiler's settle_db_us still spans
// the provider credit even though the consumer was signalled before it.
func TestSettleDBUSCoversProviderCredit(t *testing.T) {
	const creditDelay = 200 * time.Millisecond
	srv, _, _, ledger := delayedBillingServer(t, creditDelay)
	model := "settle-db-model"
	provider := registerSettlementProvider(t, srv, "settle-db-provider", model, "settle-db-account")
	usage := protocol.UsageInfo{PromptTokens: 100, CompletionTokens: 50}
	cost := payments.CalculateCost(model, usage.PromptTokens, usage.CompletionTokens)
	if err := ledger.Charge(testConsumerID, cost*2, "reserve:settle-db"); err != nil {
		t.Fatalf("reserve: %v", err)
	}
	pr := pendingForSettlement("settle-db", model, cost*2)
	rp := registry.NewRequestProfile(time.Now(), "coord-settle-db", nil, 0)
	pr.Profile = rp.NewAttempt(pr.RequestID, 0, "")
	provider.AddPending(pr)

	srv.handleComplete(provider.ID, provider, &protocol.InferenceCompleteMessage{
		Type: protocol.TypeInferenceComplete, RequestID: pr.RequestID, Usage: usage,
	})
	if got := time.Duration(pr.Profile.SettleDBUS.Load()) * time.Microsecond; got < creditDelay {
		t.Fatalf("settle_db_us = %v, want >= %v (must include the provider credit)", got, creditDelay)
	}
	// And the consumer was signalled (CompleteCh carries the usage).
	select {
	case got := <-pr.CompleteCh:
		if got != usage {
			t.Fatalf("CompleteCh usage = %+v, want %+v", got, usage)
		}
	default:
		t.Fatal("consumer was not signalled")
	}
}
