package api

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"nhooyr.io/websocket"
)

type transientSettlementStore struct {
	store.Store
	attempted chan struct{}
}

type blockingCompletionIntentStore struct {
	store.Store
	started chan struct{}
	release chan struct{}
	once    sync.Once
}

func (s *blockingCompletionIntentStore) RecordInferenceCompletionIntent(
	intent *store.InferenceCompletionIntent,
) error {
	s.once.Do(func() { close(s.started) })
	<-s.release
	return s.Store.RecordInferenceCompletionIntent(intent)
}

func (s transientSettlementStore) SettleInference(*store.InferenceSettlement) (store.InferenceSettlementDisposition, error) {
	select {
	case s.attempted <- struct{}{}:
	default:
	}
	return "", errors.New("transient database outage")
}

func TestCompletionWorkersBoundConcurrencyAndDrain(t *testing.T) {
	pool := newCompletionWorkerPool(slog.New(slog.NewTextHandler(io.Discard, nil)), 4, 2)
	release := make(chan struct{})
	started := make(chan struct{}, 4)
	var active atomic.Int32
	var maximum atomic.Int32
	var completed atomic.Int32
	for range 4 {
		if !pool.submit(func() {
			current := active.Add(1)
			for {
				previous := maximum.Load()
				if current <= previous || maximum.CompareAndSwap(previous, current) {
					break
				}
			}
			started <- struct{}{}
			<-release
			active.Add(-1)
			completed.Add(1)
		}) {
			t.Fatal("submit rejected")
		}
	}
	<-started
	<-started
	if got := maximum.Load(); got != 2 {
		t.Fatalf("maximum active workers = %d, want 2", got)
	}
	if got := pool.outstandingCount(); got != 4 {
		t.Fatalf("outstanding work = %d, want 4 queued+active tasks", got)
	}

	close(release)
	pool.close()
	if got := completed.Load(); got != 4 {
		t.Fatalf("completed tasks = %d, want 4", got)
	}
	if pool.activeCount() != 0 || pool.depth() != 0 ||
		pool.outstandingCount() != 0 || pool.capacity() != 4 {
		t.Fatalf("pool state after close: active=%d depth=%d outstanding=%d capacity=%d",
			pool.activeCount(), pool.depth(), pool.outstandingCount(), pool.capacity())
	}
}

func TestCompletionWorkersBackpressureInsteadOfDropping(t *testing.T) {
	pool := newCompletionWorkerPool(nil, 1, 1)
	release := make(chan struct{})
	started := make(chan struct{})
	if !pool.submit(func() {
		close(started)
		<-release
	}) {
		t.Fatal("first submit rejected")
	}
	<-started
	if !pool.submit(func() {}) {
		t.Fatal("queued submit rejected")
	}

	submitted := make(chan bool, 1)
	go func() {
		submitted <- pool.submit(func() {})
	}()
	select {
	case <-submitted:
		t.Fatal("submit did not backpressure on a full queue")
	case <-time.After(50 * time.Millisecond):
	}
	close(release)
	select {
	case ok := <-submitted:
		if !ok {
			t.Fatal("backpressured task was dropped")
		}
	case <-time.After(time.Second):
		t.Fatal("backpressured submit did not resume")
	}
	pool.close()
}

func TestCompletionWorkerSurvivesPanickingTask(t *testing.T) {
	pool := newCompletionWorkerPool(nil, 2, 1)
	if !pool.submit(func() { panic("test panic") }) {
		t.Fatal("panic task rejected")
	}
	completed := make(chan struct{})
	if !pool.submit(func() { close(completed) }) {
		t.Fatal("follow-up task rejected")
	}
	select {
	case <-completed:
	case <-time.After(time.Second):
		t.Fatal("worker did not survive task panic")
	}
	pool.close()
}

func TestCompletionWorkersCloseIsIdempotent(t *testing.T) {
	pool := newCompletionWorkerPool(nil, 1, 1)
	var completed atomic.Int32
	var workers sync.WaitGroup
	workers.Add(1)
	if !pool.submit(func() {
		defer workers.Done()
		completed.Add(1)
	}) {
		t.Fatal("submit rejected")
	}
	pool.close()
	pool.close()
	workers.Wait()
	if completed.Load() != 1 {
		t.Fatalf("task executed %d times", completed.Load())
	}
	if pool.submit(func() {}) {
		t.Fatal("closed pool accepted work")
	}
}

func TestCompletionClaimsPendingBeforeQueueBackpressureAndDisconnect(t *testing.T) {
	srv, store, ledger := billingTestServer(t)
	srv.completions.close()
	srv.completions = newCompletionWorkerPool(nil, 1, 1)
	t.Cleanup(srv.completions.close)

	releaseWorker := make(chan struct{})
	workerStarted := make(chan struct{})
	if !srv.completions.submit(func() {
		close(workerStarted)
		<-releaseWorker
	}) {
		t.Fatal("blocking task rejected")
	}
	<-workerStarted
	if !srv.completions.submit(func() {}) {
		t.Fatal("filler task rejected")
	}

	const (
		model         = "claimed-completion-model"
		reservationID = "claimed-completion-reservation"
		reserved      = int64(500)
	)
	initialBalance := ledger.Balance(testConsumerID)
	reservedWithdrawable, _, err := store.ReserveInferenceBalance(
		testConsumerID, reserved, reservationID,
	)
	if err != nil {
		t.Fatal(err)
	}
	provider := srv.registry.Register("claimed-completion-provider", nil, &protocol.RegisterMessage{
		Models: []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}},
	})
	pr := &registry.PendingRequest{
		RequestID: "claimed-completion-attempt", ReservationID: reservationID,
		Model: model, ConsumerKey: testConsumerID,
		ReservedMicroUSD: reserved, ReservedWithdrawableMicroUSD: reservedWithdrawable,
		BaseReservedMicroUSD: reserved, BaseReservedWithdrawableMicroUSD: reservedWithdrawable,
		ChunkCh: make(chan string, 1), CompleteCh: make(chan protocol.UsageInfo, 1),
		ErrorCh: make(chan protocol.InferenceErrorMessage, 1),
	}
	provider.AddPending(pr)
	usage := protocol.UsageInfo{PromptTokens: 1000, CompletionTokens: 1000}
	enqueued := make(chan struct{})
	go func() {
		srv.enqueueCompletion(provider.ID, provider, &protocol.InferenceCompleteMessage{
			Type: protocol.TypeInferenceComplete, RequestID: pr.RequestID, Usage: usage,
		})
		close(enqueued)
	}()

	deadline := time.Now().Add(time.Second)
	for provider.GetPending(pr.RequestID) != nil && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if provider.GetPending(pr.RequestID) != nil {
		t.Fatal("completion did not claim pending request before queue submission")
	}
	if srv.refundReservedBalance(pr, "post_terminal_sweep:"+pr.RequestID) {
		t.Fatal("post-terminal sweep refunded a terminal-claimed completion")
	}
	srv.registry.Disconnect(provider.ID)
	close(releaseWorker)
	select {
	case <-enqueued:
	case <-time.After(time.Second):
		t.Fatal("completion enqueue remained blocked")
	}
	select {
	case <-pr.CompleteCh:
	case <-time.After(time.Second):
		t.Fatal("claimed completion was lost after disconnect")
	}
	if balance := ledger.Balance(testConsumerID); balance != initialBalance-250 {
		t.Fatalf("settled balance = %d, want %d", balance, initialBalance-250)
	}
}

func TestCompletionUsesFencedPointerWhenCleanupRemovesPendingDuringIntentCommit(t *testing.T) {
	srv, backing, ledger := billingTestServer(t)
	blocking := &blockingCompletionIntentStore{
		Store: backing, started: make(chan struct{}), release: make(chan struct{}),
	}
	srv.store = blocking
	const (
		model         = "intent-race-model"
		reservationID = "intent-race-reservation"
		reserved      = int64(500)
	)
	initialBalance := ledger.Balance(testConsumerID)
	reservedWithdrawable, _, err := backing.ReserveInferenceBalance(
		testConsumerID, reserved, reservationID,
	)
	if err != nil {
		t.Fatal(err)
	}
	provider := srv.registry.Register("intent-race-provider", nil, &protocol.RegisterMessage{
		Models: []protocol.ModelInfo{{ID: model, ModelType: "chat", Quantization: "4bit"}},
	})
	pr := &registry.PendingRequest{
		RequestID: "intent-race-attempt", ReservationID: reservationID,
		Model: model, ConsumerKey: testConsumerID,
		ReservedMicroUSD: reserved, ReservedWithdrawableMicroUSD: reservedWithdrawable,
		BaseReservedMicroUSD: reserved, BaseReservedWithdrawableMicroUSD: reservedWithdrawable,
		ChunkCh: make(chan string, 1), CompleteCh: make(chan protocol.UsageInfo, 1),
		ErrorCh: make(chan protocol.InferenceErrorMessage, 1),
	}
	provider.AddPending(pr)
	done := make(chan struct{})
	go func() {
		srv.enqueueCompletion(provider.ID, provider, &protocol.InferenceCompleteMessage{
			Type: protocol.TypeInferenceComplete, RequestID: pr.RequestID,
			Usage: protocol.UsageInfo{PromptTokens: 1000, CompletionTokens: 1000},
		})
		close(done)
	}()
	select {
	case <-blocking.started:
	case <-time.After(time.Second):
		t.Fatal("completion intent did not start")
	}
	if removed := provider.RemovePending(pr.RequestID); removed != pr {
		t.Fatal("cleanup did not remove fenced pending request")
	}
	if srv.refundReservedBalance(pr, "post_terminal_sweep") {
		t.Fatal("cleanup refunded terminal-fenced request")
	}
	close(blocking.release)
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("completion did not settle via fenced pointer")
	}
	deadline := time.Now().Add(time.Second)
	for ledger.Balance(testConsumerID) != initialBalance-250 && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if balance := ledger.Balance(testConsumerID); balance != initialBalance-250 {
		t.Fatalf("fenced completion balance = %d, want %d", balance, initialBalance-250)
	}
}

func TestServerCloseJoinsUnregisteredProviderWebSocketBeforeWorkers(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	srv := NewServer(registry.New(logger), store.NewMemory(store.Config{}), ServerConfig{}, logger)
	server := httptest.NewServer(srv.Handler())
	defer server.Close()
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	connection, _, err := websocket.Dial(
		ctx,
		"ws"+strings.TrimPrefix(server.URL, "http")+"/ws/provider",
		nil,
	)
	if err != nil {
		t.Fatal(err)
	}
	defer connection.CloseNow()

	closed := make(chan struct{})
	go func() {
		srv.Close()
		close(closed)
	}()
	select {
	case <-closed:
	case <-time.After(time.Second):
		t.Fatal("Server.Close did not join provider WebSocket producer")
	}
}

func TestSettlementRetryStopsDuringBoundedShutdown(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	backing := store.NewMemory(store.Config{})
	attempted := make(chan struct{}, 1)
	srv := NewServer(registry.New(logger), transientSettlementStore{
		Store: backing, attempted: attempted,
	}, ServerConfig{}, logger)
	result := make(chan error, 1)
	go func() {
		_, err := srv.settleInferenceWithRetry(&store.InferenceSettlement{
			ReservationID: "shutdown-reservation", RequestID: "shutdown-request",
			ConsumerAccountID: "shutdown-consumer",
		})
		result <- err
	}()
	select {
	case <-attempted:
	case <-time.After(time.Second):
		t.Fatal("settlement retry did not start")
	}
	srv.StopCompletionProcessing()
	select {
	case err := <-result:
		if !errors.Is(err, errCompletionStopping) {
			t.Fatalf("shutdown retry error = %v", err)
		}
	case <-time.After(time.Second):
		t.Fatal("settlement retry blocked shutdown")
	}
	srv.Close()
}
