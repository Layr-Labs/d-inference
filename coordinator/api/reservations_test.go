package api

import (
	"errors"
	"log/slog"
	"os"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type countingStore struct {
	store.Store

	mu       sync.Mutex
	debits   int
	debitErr error
	delay    time.Duration
}

func (s *countingStore) Debit(accountID string, amountMicroUSD int64, entryType store.LedgerEntryType, reference string) error {
	if s.delay > 0 {
		time.Sleep(s.delay)
	}
	s.mu.Lock()
	s.debits++
	err := s.debitErr
	s.mu.Unlock()
	if err != nil {
		return err
	}
	return s.Store.Debit(accountID, amountMicroUSD, entryType, reference)
}

func (s *countingStore) DebitCount() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.debits
}

func newReservationTestServer(t *testing.T, cfg ServerConfig, debitErr error) (*Server, *countingStore) {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	mem := store.NewMemory(store.Config{AdminKey: "test-key"})
	st := &countingStore{Store: mem, debitErr: debitErr}
	srv := NewServer(registry.New(logger), st, cfg, logger)
	srv.SetBilling(billing.NewService(st, payments.NewLedger(st), logger, billing.Config{MockMode: true}))
	return srv, st
}

func createServiceUser(t *testing.T, st store.Store, accountID string) {
	t.Helper()
	if err := st.CreateUser(&store.User{AccountID: accountID, PrivyUserID: "did:privy:" + accountID, Role: store.RoleService}); err != nil {
		t.Fatal(err)
	}
}

func TestServiceReservationDisabledUsesLedgerDebit(t *testing.T) {
	srv, st := newReservationTestServer(t, ServerConfig{}, nil)
	createServiceUser(t, st, "svc-disabled")
	if err := st.Credit("svc-disabled", 1_000_000, store.LedgerDeposit, "seed"); err != nil {
		t.Fatal(err)
	}

	serviceMode, err := srv.inferenceSettlement().Reserve("svc-disabled", "model", 100_000)
	if err != nil {
		t.Fatal(err)
	}
	if serviceMode {
		t.Fatal("service reservations should be disabled by default")
	}
	if got := st.DebitCount(); got != 1 {
		t.Fatalf("Debit calls = %d, want 1", got)
	}
}

func TestNormalConsumerStillUsesSynchronousDebit(t *testing.T) {
	srv, st := newReservationTestServer(t, ServerConfig{ServiceReservations: true}, store.ErrInsufficientBalance)
	if err := st.Credit("consumer", 1_000_000, store.LedgerDeposit, "seed"); err != nil {
		t.Fatal(err)
	}

	serviceMode, err := srv.inferenceSettlement().Reserve("consumer", "model", 100_000)
	if !errors.Is(err, store.ErrInsufficientBalance) {
		t.Fatalf("err = %v, want ErrInsufficientBalance", err)
	}
	if serviceMode {
		t.Fatal("normal consumer used service reservation mode")
	}
	if got := st.DebitCount(); got != 1 {
		t.Fatalf("Debit calls = %d, want 1", got)
	}
}

func TestServiceReservationRefundReleasesHoldWithoutCredit(t *testing.T) {
	srv, st := newReservationTestServer(t, ServerConfig{ServiceReservations: true}, nil)
	createServiceUser(t, st, "svc-refund")
	if err := st.Credit("svc-refund", 1_000_000, store.LedgerDeposit, "seed"); err != nil {
		t.Fatal(err)
	}
	serviceMode, err := srv.inferenceSettlement().Reserve("svc-refund", "model", 250_000)
	if err != nil || !serviceMode {
		t.Fatalf("reserve serviceMode=%v err=%v", serviceMode, err)
	}

	pr := &registry.PendingRequest{RequestID: "svc-refund", Model: "model", ConsumerKey: "svc-refund", ReservedMicroUSD: 250_000, ServiceReservation: true}
	if !srv.inferenceSettlement().Refund(pr, "test") {
		t.Fatal("refundReservedBalance returned false")
	}
	if got := st.GetBalance("svc-refund"); got != 1_000_000 {
		t.Fatalf("balance = %d, want unchanged 1000000", got)
	}
	if srv.inferenceSettlement().Refund(pr, "test-again") {
		t.Fatal("second refund should be finalized/no-op")
	}
}

func TestServiceReservationCompletionDebitsActualAndReleasesHold(t *testing.T) {
	srv, st := newReservationTestServer(t, ServerConfig{ServiceReservations: true}, nil)
	createServiceUser(t, st, "svc-complete")
	if err := st.Credit("svc-complete", 1_000_000, store.LedgerDeposit, "seed"); err != nil {
		t.Fatal(err)
	}
	if err := st.SetModelPrice("platform", "svc-model", 1_000_000, 2_000_000); err != nil {
		t.Fatal(err)
	}
	serviceMode, err := srv.inferenceSettlement().Reserve("svc-complete", "svc-model", 500_000)
	if err != nil || !serviceMode {
		t.Fatalf("reserve serviceMode=%v err=%v", serviceMode, err)
	}

	provider := srv.registry.Register("svc-provider", nil, &protocol.RegisterMessage{Models: []protocol.ModelInfo{{ID: "svc-model", ModelType: "chat", Quantization: "4bit"}}})
	pr := &registry.PendingRequest{
		RequestID:          "svc-complete",
		Model:              "svc-model",
		ConsumerKey:        "svc-complete",
		ReservedMicroUSD:   500_000,
		ServiceReservation: true,
		ChunkCh:            make(chan registry.ProviderChunk, 1),
		CompleteCh:         make(chan protocol.UsageInfo, 1),
		ErrorCh:            make(chan protocol.InferenceErrorMessage, 1),
	}
	provider.AddPending(pr)

	usage := protocol.UsageInfo{PromptTokens: 10, CompletionTokens: 20}
	expected := payments.CalculateCostWithOverridesNoMinimum("svc-model", usage.PromptTokens, usage.CompletionTokens, 1_000_000, 2_000_000, true)
	srv.handleComplete(provider.ID, provider, &protocol.InferenceCompleteMessage{Type: protocol.TypeInferenceComplete, RequestID: pr.RequestID, Usage: usage})

	if got := st.DebitCount(); got != 1 {
		t.Fatalf("Debit calls = %d, want 1 completion settlement debit", got)
	}
	if got := st.GetBalance("svc-complete"); got != 1_000_000-expected {
		t.Fatalf("balance = %d, want %d", got, 1_000_000-expected)
	}
}
