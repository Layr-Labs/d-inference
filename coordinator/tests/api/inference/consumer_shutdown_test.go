package inference_test

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http/httptest"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
	"nhooyr.io/websocket"
)

type blockedConsumerPricingStore struct {
	*uncertainConsumerStore
	entered, release chan struct{}
	once             sync.Once
}

func (s *blockedConsumerPricingStore) GetUserByAccountID(account string) (*store.User, error) {
	if account == "closing-consumer" {
		s.once.Do(func() { close(s.entered); <-s.release })
	}
	return s.Store.GetUserByAccountID(account)
}

func TestConsumerSettlementShutdownJoinsOffLoopCompletion(t *testing.T) {
	for _, protocolExit := range []bool{false, true} {
		t.Run(map[bool]string{false: "network_close", true: "duplicate_registration"}[protocolExit], func(t *testing.T) {
			testConsumerShutdownCompletion(t, protocolExit)
		})
	}
}

func testConsumerShutdownCompletion(t *testing.T, protocolExit bool) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	mem := memory.NewMemory(store.Config{AdminKey: "test-key"})
	backend := &blockedConsumerPricingStore{uncertainConsumerStore: &uncertainConsumerStore{Store: mem, usage: make(chan struct{}, 1)}, entered: make(chan struct{}), release: make(chan struct{})}
	backend.remaining.Store(3)
	var release sync.Once
	unblock := func() { release.Do(func() { close(backend.release) }) }
	defer unblock()
	srv := newComposedServer(registry.New(logger), backend, TestServerConfig{}, logger)
	t.Cleanup(srv.Close)
	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(ts.Close)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	conn, id, _ := setupProviderForBilling(t, ctx, ts, srv.registry, "closing-model")
	defer conn.CloseNow()
	if err := mem.Credit("closing-consumer", 1000, store.LedgerDeposit, "seed"); err != nil {
		t.Fatal(err)
	}
	if err := mem.Debit("closing-consumer", 1000, store.LedgerCharge, "reserve"); err != nil {
		t.Fatal(err)
	}
	pr := &registry.PendingRequest{RequestID: "closing-job", ConsumerKey: "closing-consumer", Model: "closing-model", ReservedMicroUSD: 1000, ChunkCh: make(chan registry.ProviderChunk, 1), CompleteCh: make(chan protocol.UsageInfo, 1), ErrorCh: make(chan protocol.InferenceErrorMessage, 1)}
	provider := srv.registry.GetProvider(id)
	provider.AddPending(pr)
	data, err := json.Marshal(protocol.InferenceCompleteMessage{Type: protocol.TypeInferenceComplete, RequestID: pr.RequestID, Usage: protocol.UsageInfo{PromptTokens: 1, CompletionTokens: 1}})
	if err != nil {
		t.Fatal(err)
	}
	if err := conn.Write(ctx, websocket.MessageText, data); err != nil {
		t.Fatal(err)
	}
	select {
	case <-backend.entered:
	case <-ctx.Done():
		t.Fatal("completion never reached pricing")
	}
	if protocolExit {
		if err := conn.Write(ctx, websocket.MessageText, []byte(`{"type":"register"}`)); err != nil {
			t.Fatal(err)
		}
		// Read acknowledges the close frame so the server enters teardown
		// without waiting for its WebSocket close-handshake timeout.
		for {
			if _, _, err := conn.Read(ctx); err != nil {
				break
			}
		}
		deadline := time.Now().Add(time.Second)
		for {
			provider.Mu().Lock()
			status := provider.Status
			provider.Mu().Unlock()
			if status == registry.StatusOffline {
				break
			}
			if time.Now().After(deadline) {
				t.Fatal("protocol-error exit kept a blocked provider routable")
			}
			time.Sleep(time.Millisecond)
		}
	}
	// No HTTP request is in flight. Only the off-loop terminal owns this job,
	// and it has not yet registered any pending reconciliation or usage write.
	joinCtx, joinCancel := context.WithTimeout(ctx, 100*time.Millisecond)
	joined := srv.server.CloseProviderConnections(joinCtx)
	joinCancel()
	unblock()
	if joined {
		t.Fatal("socket handler join skipped its blocked completion worker")
	}
	if !srv.server.WaitProviderHandlers(ctx) {
		t.Fatal("completion worker failed to finish")
	}
	srv.Close()
	if rows := mem.UsageByConsumer("closing-consumer"); len(rows) != 1 {
		t.Fatalf("shutdown lost completed usage: %+v", rows)
	}
	if mem.GetWithdrawableBalance("test-account-"+id) == 0 {
		t.Fatal("shutdown lost provider payout")
	}
}
