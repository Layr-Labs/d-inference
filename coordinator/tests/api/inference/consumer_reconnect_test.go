package inference_test

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
	"nhooyr.io/websocket"
)

func TestConsumerSettlementReconnectKeepsNewSessionWhileOldCompletionDrains(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	mem := memory.NewMemory(store.Config{AdminKey: "test-key"})
	backend := &blockedConsumerPricingStore{uncertainConsumerStore: &uncertainConsumerStore{Store: mem, usage: make(chan struct{}, 10)}, entered: make(chan struct{}), release: make(chan struct{})}
	var release sync.Once
	unblock := func() { release.Do(func() { close(backend.release) }) }
	defer unblock()
	srv := newComposedServer(registry.New(logger), backend, TestServerConfig{}, logger)
	t.Cleanup(srv.Close)
	ts := httptest.NewServer(srv.Handler())
	t.Cleanup(ts.Close)
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	const account, token, model = "reconnected-account", "reconnected-token", "reconnected-model"
	if err := mem.CreateProviderToken(&store.ProviderToken{TokenHash: sha256HexStr(token), AccountID: account, Active: true}); err != nil {
		t.Fatal(err)
	}
	for _, consumer := range []string{"closing-consumer", testConsumerID} {
		if err := mem.Credit(consumer, 1_000_000, store.LedgerDeposit, "seed"); err != nil {
			t.Fatal(err)
		}
	}
	key := testPublicKeyB64()
	models := []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}}
	oldConn := connectProviderWithToken(t, ctx, ts.URL, models, key, token)
	defer oldConn.CloseNow()
	readAttestationChallenge(t, ctx, oldConn)
	ids := srv.registry.ProviderIDs()
	if len(ids) != 1 {
		t.Fatalf("initial providers=%v", ids)
	}
	old := srv.registry.GetProvider(ids[0])
	if err := mem.Debit("closing-consumer", 1000, store.LedgerCharge, "reserve"); err != nil {
		t.Fatal(err)
	}
	pr := &registry.PendingRequest{RequestID: "reconnect-old-job", ConsumerKey: "closing-consumer", Model: model, ReservedMicroUSD: 1000, ChunkCh: make(chan registry.ProviderChunk, 1), CompleteCh: make(chan protocol.UsageInfo, 1), ErrorCh: make(chan protocol.InferenceErrorMessage, 1)}
	old.AddPending(pr)
	usage := protocol.UsageInfo{PromptTokens: 1, CompletionTokens: 1}
	data, err := json.Marshal(protocol.InferenceCompleteMessage{Type: protocol.TypeInferenceComplete, RequestID: pr.RequestID, Usage: usage})
	if err != nil {
		t.Fatal(err)
	}
	if err := oldConn.Write(ctx, websocket.MessageText, data); err != nil {
		t.Fatal(err)
	}
	select {
	case <-backend.entered:
	case <-ctx.Done():
		t.Fatal("old completion never reached pricing")
	}
	oldConn.CloseNow()
	for {
		old.Mu().Lock()
		offline := old.Status == registry.StatusOffline
		old.Mu().Unlock()
		if offline {
			break
		}
		select {
		case <-ctx.Done():
			t.Fatal("old provider did not go offline")
		case <-time.After(time.Millisecond):
		}
	}
	if srv.registry.GetProvider(old.ID) != old {
		t.Fatal("test requires old provider retained by blocked completion")
	}

	// The stable provider identity is unchanged. Only the server-generated
	// connection UUID should differ, including while the old entry still exists.
	newConn := connectProviderWithToken(t, ctx, ts.URL, models, key, token)
	defer newConn.CloseNow()
	readAttestationChallenge(t, ctx, newConn)
	var current *registry.Provider
	for _, id := range srv.registry.ProviderIDs() {
		if id != old.ID {
			current = srv.registry.GetProvider(id)
		}
	}
	if current == nil || current == old || current.Conn == old.Conn {
		t.Fatal("reconnect reused old provider or socket")
	}
	current.Mu().Lock()
	linkedAccount, publicKey := current.AccountID, current.PublicKey
	current.Mu().Unlock()
	if linkedAccount != account || publicKey != key {
		t.Fatal("reconnect changed stable provider identity")
	}
	srv.registry.SetTrustLevel(current.ID, registry.TrustHardware)
	srv.registry.RecordChallengeSuccess(current.ID)
	serve := func() {
		t.Helper()
		done := serveOneInference(ctx, t, newConn, key, usage)
		if status := sendInferenceRequest(t, ctx, ts.URL, model, "test-key"); status != http.StatusOK {
			t.Fatalf("reconnected inference status=%d", status)
		}
		select {
		case <-done:
		case <-ctx.Done():
			t.Fatal("new provider did not serve inference")
		}
	}
	serve()
	unblock()
	for srv.registry.GetProvider(old.ID) != nil {
		select {
		case <-ctx.Done():
			t.Fatal("old provider teardown did not finish")
		case <-time.After(time.Millisecond):
		}
	}
	if srv.registry.GetProvider(current.ID) != current {
		t.Fatal("old teardown removed new session")
	}
	current.Mu().Lock()
	status := current.Status
	current.Mu().Unlock()
	if status != registry.StatusOnline {
		t.Fatalf("new provider status after old teardown=%s", status)
	}
	serve()
	srv.Close() // join the asynchronous usage writes before checking all jobs
	rows := mem.UsageByConsumer("closing-consumer")
	cost := payments.DefaultRates().CostWithMinimum(payments.Usage{PromptTokens: 1, CompletionTokens: 1})
	if len(rows) != 1 || rows[0].RequestID != pr.RequestID || rows[0].CostMicroUSD != cost {
		t.Fatalf("old accounting was not preserved: %+v", rows)
	}
	if mem.GetBalance("closing-consumer") != 1_000_000-cost {
		t.Fatal("old consumer charge changed")
	}
	if got := mem.GetWithdrawableBalance(account); got != 3*payments.ProviderPayout(cost) {
		t.Fatalf("provider payout=%d want=%d", got, 3*payments.ProviderPayout(cost))
	}
}
