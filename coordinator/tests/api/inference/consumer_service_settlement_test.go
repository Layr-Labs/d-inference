package inference_test

import (
	"errors"
	"io"
	"log/slog"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

func TestConsumerSettlementRetainsServiceHoldUntilRecovered(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	mem := memory.NewMemory(store.Config{})
	backend := &uncertainConsumerStore{Store: mem, usage: make(chan struct{}, 10)}
	backend.remaining.Store(3)
	srv := newComposedServer(registry.New(logger), backend, TestServerConfig{ServiceReservations: true}, logger)
	t.Cleanup(srv.Close)
	const account, model = "service-consumer", "service-model"
	fee := int64(0)
	if err := mem.CreateUser(&store.User{AccountID: account, PrivyUserID: "service-privy", Role: store.RoleService, PlatformFeePercent: &fee}); err != nil {
		t.Fatal(err)
	}
	if err := mem.Credit(account, 1000, store.LedgerDeposit, "seed"); err != nil {
		t.Fatal(err)
	}
	if err := mem.SetModelPrice(store.ModelPrice{AccountID: "platform", Model: model, InputPrice: 1_000_000, OutputPrice: 2_000_000}); err != nil {
		t.Fatal(err)
	}
	if service, err := srv.reservations.ReserveInitial(account, model, 1000); !service || err != nil {
		t.Fatalf("reserve service=%v err=%v", service, err)
	}
	provider := srv.registry.Register("service-provider", nil, &protocol.RegisterMessage{Models: []protocol.ModelInfo{{ID: model, ModelType: "chat"}}})
	provider.Mu().Lock()
	provider.AccountID = "service-provider-account"
	provider.Mu().Unlock()
	request := func() *registry.PendingRequest {
		return &registry.PendingRequest{RequestID: "service-job", ConsumerKey: account, Model: model, ReservedMicroUSD: 1000, ServiceReservation: true, ChunkCh: make(chan registry.ProviderChunk, 1), CompleteCh: make(chan protocol.UsageInfo, 1), ErrorCh: make(chan protocol.InferenceErrorMessage, 1)}
	}
	pr := request()
	provider.AddPending(pr)
	terminal := &protocol.InferenceCompleteMessage{Type: protocol.TypeInferenceComplete, RequestID: pr.RequestID, Usage: protocol.UsageInfo{PromptTokens: 100, CompletionTokens: 200}}
	srv.HandleCompleteAt(provider.ID, provider, terminal, time.Now())
	if _, err := srv.reservations.ReserveInitial(account, model, 1); !errors.Is(err, store.ErrInsufficientBalance) {
		t.Fatalf("queued settlement released its service hold: %v", err)
	}
	if srv.reservations.Refund(pr, "timeout") {
		t.Fatal("timeout released queued service hold")
	}
	srv.Close() // final reconciliation after the normal maintenance loop stopped
	if mem.GetBalance(account) != 500 || mem.GetWithdrawableBalance("service-provider-account") != 500 {
		t.Fatal("service charge and provider payout were not recovered")
	}
	if service, err := srv.reservations.ReserveInitial(account, model, 500); !service || err != nil {
		t.Fatalf("recovered settlement leaked its service hold: service=%v err=%v", service, err)
	}
	provider.AddPending(request())
	srv.HandleCompleteAt(provider.ID, provider, terminal, time.Now())
	if _, err := srv.reservations.ReserveInitial(account, model, 1); !errors.Is(err, store.ErrInsufficientBalance) {
		t.Fatalf("replay released another request's hold: %v", err)
	}
}
