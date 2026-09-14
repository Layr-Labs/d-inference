package api

import (
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type completionCreditBarrierStore struct {
	store.Store
	entered chan struct{}
	release chan struct{}
}

func (s *completionCreditBarrierStore) CreditProviderAccount(earning *store.ProviderEarning) error {
	close(s.entered)
	<-s.release
	return s.Store.CreditProviderAccount(earning)
}

// Completion must publish usage before credits, then finish those credits before
// opening the consumer's terminal channels. The barrier wraps the real store.
func TestCompletionPublishesUsageBeforeCreditsAndConsumerTerminal(t *testing.T) {
	srv, st, ledger := billingTestServer(t)
	const model, account = "completion-order-model", "completion-order-provider"
	provider := srv.registry.Register("completion-order-session", nil, &protocol.RegisterMessage{
		Models: []protocol.ModelInfo{{ID: model, ModelType: "chat"}},
	})
	provider.Mu().Lock()
	provider.AccountID = account
	provider.Mu().Unlock()
	usage := protocol.UsageInfo{PromptTokens: 100, CompletionTokens: 200}
	cost := payments.CalculateCost(model, usage.PromptTokens, usage.CompletionTokens)
	initial := ledger.Balance(testConsumerID)
	if err := ledger.Charge(testConsumerID, cost, "reserve:completion-order"); err != nil {
		t.Fatal(err)
	}
	pr := &registry.PendingRequest{
		RequestID: "completion-order", Model: model, ConsumerKey: testConsumerID,
		ReservedMicroUSD: cost,
		ChunkCh:          make(chan registry.ProviderChunk, 1),
		CompleteCh:       make(chan protocol.UsageInfo, 1),
		ErrorCh:          make(chan protocol.InferenceErrorMessage, 1),
	}
	provider.AddPending(pr)
	barrier := &completionCreditBarrierStore{Store: st, entered: make(chan struct{}), release: make(chan struct{})}
	srv.store = barrier
	release := sync.OnceFunc(func() { close(barrier.release) })
	done := make(chan struct{})
	go func() {
		defer close(done)
		srv.handleComplete(provider.ID, provider, &protocol.InferenceCompleteMessage{
			Type: protocol.TypeInferenceComplete, RequestID: pr.RequestID, Usage: usage,
		})
	}()
	t.Cleanup(func() {
		release()
		select {
		case <-done:
		case <-time.After(2 * time.Second):
			t.Error("completion did not finish after releasing provider credit")
		}
	})
	select {
	case <-barrier.entered:
	case <-time.After(2 * time.Second):
		t.Fatal("completion did not reach provider credit through the current store")
	}
	entries := ledger.Usage(testConsumerID)
	if len(entries) != 1 || entries[0].JobID != pr.RequestID || entries[0].CostMicroUSD != cost {
		t.Fatalf("usage before provider credit = %+v, want the completed charge", entries)
	}
	if got := ledger.Balance(testConsumerID); got != initial-cost {
		t.Fatalf("consumer balance = %d, want %d", got, initial-cost)
	}
	if got := st.GetWithdrawableBalance(account); got != 0 {
		t.Fatalf("provider credit escaped its barrier: %d", got)
	}
	select {
	case <-pr.CompleteCh:
		t.Fatal("consumer completion published before provider credit finished")
	default:
	}
	select {
	case <-pr.ChunkCh:
		t.Fatal("consumer chunk channel closed before provider credit finished")
	default:
	}
	release()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("completion did not return after credit finished")
	}
	select {
	case got, ok := <-pr.CompleteCh:
		if !ok || got != usage {
			t.Fatalf("consumer terminal = %+v, open=%v; want usage %+v", got, ok, usage)
		}
	default:
		t.Fatal("completion returned without publishing consumer usage")
	}
	select {
	case _, ok := <-pr.ChunkCh:
		if ok {
			t.Fatal("completion did not close the consumer chunk channel")
		}
	default:
		t.Fatal("completion returned without closing the consumer chunk channel")
	}
	if got := st.GetWithdrawableBalance(account); got != payments.ProviderPayout(cost) {
		t.Fatalf("provider credit = %d, want %d", got, payments.ProviderPayout(cost))
	}
}
