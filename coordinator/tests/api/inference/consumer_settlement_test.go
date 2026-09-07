package inference_test

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

type uncertainConsumerStore struct {
	store.Store
	remaining   atomic.Int32
	afterCommit bool
	usage       chan struct{}
}

func (s *uncertainConsumerStore) FinalizeConsumerCharge(in store.ConsumerChargeSettlement) (store.ConsumerChargeResult, error) {
	fail := s.remaining.Add(-1) >= 0
	if fail && !s.afterCommit {
		return store.ConsumerChargeResult{}, errors.New("settlement unavailable")
	}
	result, err := s.Store.FinalizeConsumerCharge(in)
	if err == nil && fail {
		return store.ConsumerChargeResult{}, errors.New("commit acknowledgement lost")
	}
	return result, err
}

func (s *uncertainConsumerStore) RecordUsage(rec store.UsageRecord) {
	s.Store.RecordUsage(rec)
	s.usage <- struct{}{}
}

func TestConsumerSettlementRecoveryRestoresProviderAndUsage(t *testing.T) {
	for _, mode := range []struct {
		name                  string
		afterCommit, shutdown bool
	}{
		{"before_commit", false, false}, {"after_commit", true, false},
		{"shutdown_before_commit", false, true}, {"shutdown_after_commit", true, true},
	} {
		t.Run(mode.name, func(t *testing.T) {
			logger := slog.New(slog.NewTextHandler(io.Discard, nil))
			mem := memory.NewMemory(store.Config{})
			backend := &uncertainConsumerStore{Store: mem, afterCommit: mode.afterCommit, usage: make(chan struct{}, 10)}
			backend.remaining.Store(3)
			srv := newComposedServer(registry.New(logger), backend, TestServerConfig{}, logger)
			t.Cleanup(srv.Close)
			srv.bindBilling(billing.NewService(backend, srv.ledger, logger, billing.Config{MockMode: true}))
			const consumer, referrer, account, model = "recovery-consumer", "recovery-referrer", "recovery-provider", "recovery-model"
			fee := int64(20)
			if err := mem.CreateUser(&store.User{AccountID: consumer, PrivyUserID: "recovery-privy", PlatformFeePercent: &fee}); err != nil {
				t.Fatal(err)
			}
			if err := mem.Credit(consumer, 1_000_000, store.LedgerDeposit, "seed"); err != nil {
				t.Fatal(err)
			}
			if err := mem.CreateReferrer(referrer, "RECOVERY"); err != nil {
				t.Fatal(err)
			}
			if err := mem.RecordReferral("RECOVERY", consumer); err != nil {
				t.Fatal(err)
			}
			if err := mem.SetModelPrice(store.ModelPrice{AccountID: "platform", Model: model, InputPrice: 1_000_000, OutputPrice: 2_000_000}); err != nil {
				t.Fatal(err)
			}
			usage := protocol.UsageInfo{PromptTokens: 100, CompletionTokens: 200}
			cost := payments.Rates{Input: 1_000_000, Output: 2_000_000}.CostWithMinimum(payments.Usage{PromptTokens: 100, CompletionTokens: 200})
			reserved := cost * 2
			if err := mem.Debit(consumer, reserved, store.LedgerCharge, "reserve"); err != nil {
				t.Fatal(err)
			}
			provider := srv.registry.Register("recovery-provider-key", nil, &protocol.RegisterMessage{Models: []protocol.ModelInfo{{ID: model, ModelType: "chat"}}})
			provider.Mu().Lock()
			provider.AccountID = account
			provider.Mu().Unlock()
			request := func() *registry.PendingRequest {
				return &registry.PendingRequest{RequestID: "recovery-job", ConsumerKey: consumer, Model: model, ReservedMicroUSD: reserved, ChunkCh: make(chan registry.ProviderChunk, 1), CompleteCh: make(chan protocol.UsageInfo, 1), ErrorCh: make(chan protocol.InferenceErrorMessage, 1)}
			}
			pr := request()
			provider.AddPending(pr)
			terminal := &protocol.InferenceCompleteMessage{Type: protocol.TypeInferenceComplete, RequestID: pr.RequestID, Usage: usage}
			if mode.shutdown {
				// Shutdown stops normal maintenance before in-flight terminals drain.
				stopped, stop := context.WithCancel(context.Background())
				stop()
				srv.RunModelTokenMaintenance(stopped)
			}
			srv.HandleCompleteAt(provider.ID, provider, terminal, time.Now())
			if !pr.IsReservationFinalized() {
				t.Fatal("ambiguous settlement left refund gate open")
			}
			if mem.GetWithdrawableBalance(account) != 0 || len(mem.UsageByConsumer(consumer)) != 0 {
				t.Fatal("accounting ran before settlement recovered")
			}
			if mode.shutdown {
				srv.Close()
				if len(backend.usage) != 1 {
					t.Fatal("shutdown failed to join the recovered usage write")
				}
			} else {
				ctx, cancel := context.WithCancel(context.Background())
				defer cancel()
				done := make(chan struct{})
				go func() { defer close(done); srv.RunModelTokenMaintenance(ctx) }()
				select {
				case <-backend.usage:
				case <-time.After(5 * time.Second):
					t.Fatal("settlement recovery did not restore usage")
				}
				cancel()
				select {
				case <-done:
				case <-time.After(5 * time.Second):
					t.Fatal("maintenance failed to stop")
				}
			}
			// A repeated terminal with a fresh in-memory request must not repeat
			// the downstream non-idempotent credits recovered by maintenance.
			provider.AddPending(request())
			srv.HandleCompleteAt(provider.ID, provider, terminal, time.Now())
			if got := mem.GetBalance(consumer); got != 1_000_000-cost {
				t.Fatalf("consumer balance=%d", got)
			}
			if got := mem.GetWithdrawableBalance(referrer); got != cost*store.ConsumerReferralPercent/100 {
				t.Fatalf("referral reward=%d", got)
			}
			if got := mem.GetWithdrawableBalance(account); got != payments.ProviderPayoutWithPercent(cost, &fee) {
				t.Fatalf("provider payout=%d", got)
			}
			if got := mem.GetBalance("platform"); got != payments.PlatformFeeWithPercent(cost, &fee) {
				t.Fatalf("platform fee=%d", got)
			}
			rows := mem.UsageByConsumer(consumer)
			if len(rows) != 1 || rows[0].CostMicroUSD != cost {
				t.Fatalf("usage=%+v", rows)
			}
		})
	}
}

func TestConsumerSettlementUncollectedFunding(t *testing.T) {
	for _, mode := range []string{"platform_covered", "self_route_fallback", "service"} {
		t.Run(mode, func(t *testing.T) {
			srv, mem, ledger := billingTestServer(t)
			t.Cleanup(srv.Close)
			const consumer, referrer, account, model = "unfunded-consumer", "unfunded-referrer", "unfunded-provider", "unfunded-model"
			if err := mem.CreateReferrer(referrer, "UNFUNDED"); err != nil {
				t.Fatal(err)
			}
			if err := mem.RecordReferral("UNFUNDED", consumer); err != nil {
				t.Fatal(err)
			}
			provider := srv.registry.Register("unfunded-provider-key", nil, &protocol.RegisterMessage{Models: []protocol.ModelInfo{{ID: model, ModelType: "chat"}}})
			provider.Mu().Lock()
			provider.AccountID = account
			provider.Mu().Unlock()
			pr := &registry.PendingRequest{RequestID: "unfunded-job", ConsumerKey: consumer, Model: model, FreeSelfRoute: mode == "self_route_fallback", ServiceReservation: mode == "service", ChunkCh: make(chan registry.ProviderChunk, 1), CompleteCh: make(chan protocol.UsageInfo, 1), ErrorCh: make(chan protocol.InferenceErrorMessage, 1)}
			provider.AddPending(pr)
			usage := protocol.UsageInfo{PromptTokens: 100, CompletionTokens: 200}
			srv.HandleCompleteAt(provider.ID, provider, &protocol.InferenceCompleteMessage{Type: protocol.TypeInferenceComplete, RequestID: pr.RequestID, Usage: usage}, time.Now())
			var cost int64
			if mode == "platform_covered" {
				cost = payments.DefaultRates().CostWithMinimum(payments.Usage{PromptTokens: 100, CompletionTokens: 200})
			}
			if got := mem.GetWithdrawableBalance(account); got != payments.ProviderPayout(cost) {
				t.Fatalf("provider payout=%d want=%d", got, payments.ProviderPayout(cost))
			}
			if mem.GetBalance(consumer) != 0 || mem.GetBalance(referrer) != 0 {
				t.Fatal("uncollected request changed consumer/referrer funds")
			}
			if rows := ledger.Usage(consumer); len(rows) != 1 || rows[0].CostMicroUSD != cost {
				t.Fatalf("usage=%+v want cost=%d", rows, cost)
			}
		})
	}
}
