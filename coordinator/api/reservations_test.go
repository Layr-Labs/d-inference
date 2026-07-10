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

type ambiguousReserveStore struct {
	store.Store
	mu       sync.Mutex
	injected bool
	attempts int
}

func (s *ambiguousReserveStore) ReserveInferenceBalance(accountID string, amountMicroUSD int64, operationKey string) (int64, bool, error) {
	s.mu.Lock()
	s.attempts++
	inject := !s.injected
	if inject {
		s.injected = true
	}
	s.mu.Unlock()
	reservedWithdrawable, applied, err := s.Store.ReserveInferenceBalance(
		accountID, amountMicroUSD, operationKey,
	)
	if inject && err == nil {
		return 0, false, errors.New("ambiguous reservation commit")
	}
	return reservedWithdrawable, applied, err
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

func (s *countingStore) ReserveInferenceBalance(accountID string, amountMicroUSD int64, operationKey string) (int64, bool, error) {
	if s.delay > 0 {
		time.Sleep(s.delay)
	}
	s.mu.Lock()
	s.debits++
	err := s.debitErr
	s.mu.Unlock()
	if err != nil {
		return 0, false, err
	}
	return s.Store.ReserveInferenceBalance(accountID, amountMicroUSD, operationKey)
}

func (s *countingStore) SettleInference(settlement *store.InferenceSettlement) (store.InferenceSettlementDisposition, error) {
	if !settlement.ReservationPreDebited {
		if s.delay > 0 {
			time.Sleep(s.delay)
		}
		s.mu.Lock()
		s.debits++
		err := s.debitErr
		s.mu.Unlock()
		if err != nil {
			return "", err
		}
	}
	return s.Store.SettleInference(settlement)
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

	serviceMode, _, err := srv.reserveInitialBalance("svc-disabled", "model", 100_000, "reserve-disabled")
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

func TestServiceReservationConcurrentAvoidsDebitHotRow(t *testing.T) {
	srv, st := newReservationTestServer(t, ServerConfig{ServiceReservations: true}, errors.New("hot row unavailable"))
	createServiceUser(t, st, "svc-hotrow")
	if err := st.Credit("svc-hotrow", 10_000_000, store.LedgerDeposit, "seed"); err != nil {
		t.Fatal(err)
	}

	const workers = 32
	var wg sync.WaitGroup
	errs := make(chan error, workers)
	for range workers {
		wg.Add(1)
		go func() {
			defer wg.Done()
			serviceMode, _, err := srv.reserveInitialBalance("svc-hotrow", "model", 100_000, "reserve-hotrow")
			if err != nil {
				errs <- err
				return
			}
			if !serviceMode {
				errs <- errors.New("expected service reservation mode")
			}
		}()
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		if err != nil {
			t.Fatal(err)
		}
	}
	if got := st.DebitCount(); got != 0 {
		t.Fatalf("Debit calls = %d, want 0", got)
	}
}

func TestServiceReservationUsesPostSettlementBalanceBeforeReadmitting(t *testing.T) {
	backing := store.NewMemory(store.Config{})
	const accountID = "service-readmit"
	if err := backing.Credit(accountID, 1_000_000, store.LedgerStripeDeposit, "deposit"); err != nil {
		t.Fatal(err)
	}
	manager := newServiceReservationManager(backing, true)
	if err := manager.Reserve(accountID, 600_000); err != nil {
		t.Fatal(err)
	}
	if err := backing.Debit(accountID, 500_000, store.LedgerCharge, "settlement"); err != nil {
		t.Fatal(err)
	}
	if err := manager.Reserve(accountID, 300_000); !errors.Is(err, store.ErrInsufficientBalance) {
		t.Fatalf("readmission against post-settlement balance error = %v", err)
	}
	manager.Release(accountID, 600_000)
	if err := manager.Reserve(accountID, 300_000); err != nil {
		t.Fatalf("readmission after old hold release: %v", err)
	}
}

func TestNormalConsumerStillUsesSynchronousDebit(t *testing.T) {
	srv, st := newReservationTestServer(t, ServerConfig{ServiceReservations: true}, store.ErrInsufficientBalance)
	if err := st.Credit("consumer", 1_000_000, store.LedgerDeposit, "seed"); err != nil {
		t.Fatal(err)
	}

	serviceMode, _, err := srv.reserveInitialBalance("consumer", "model", 100_000, "reserve-consumer")
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

func TestInitialReservationResolvesAmbiguousCommitWithSameOperationKey(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, nil))
	backing := store.NewMemory(store.Config{})
	if err := backing.Credit("ambiguous-consumer", 20_000, store.LedgerStripeDeposit, "deposit"); err != nil {
		t.Fatal(err)
	}
	if err := backing.CreditWithdrawable("ambiguous-consumer", 30_000, store.LedgerPayout, "earning"); err != nil {
		t.Fatal(err)
	}
	ambiguous := &ambiguousReserveStore{Store: backing}
	srv := NewServer(registry.New(logger), ambiguous, ServerConfig{}, logger)
	service, reservedWithdrawable, err := srv.reserveInitialBalance(
		"ambiguous-consumer", "model", 25_000, "ambiguous-reservation",
	)
	if err != nil || service {
		t.Fatalf("reserve service=%t withdrawable=%d err=%v", service, reservedWithdrawable, err)
	}
	if ambiguous.attempts != 2 || reservedWithdrawable != 5_000 {
		t.Fatalf("ambiguous replay attempts=%d withdrawable=%d, want 2/5000",
			ambiguous.attempts, reservedWithdrawable)
	}
	if balance, withdrawable := backing.GetBalanceWithWithdrawable("ambiguous-consumer"); balance != 25_000 || withdrawable != 25_000 {
		t.Fatalf("balance = %d/%d, want one debit 25000/25000", balance, withdrawable)
	}
}

func TestProviderTopUpResolvesAmbiguousCommitAndCanRefund(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(os.Stderr, nil))
	backing := store.NewMemory(store.Config{})
	const accountID = "ambiguous-topup-consumer"
	if err := backing.CreditWithdrawable(accountID, 10_000_000, store.LedgerPayout, "earning"); err != nil {
		t.Fatal(err)
	}
	baseWithdrawable, _, err := backing.ReserveInferenceBalance(accountID, 100, "topup-base")
	if err != nil {
		t.Fatal(err)
	}
	ambiguous := &ambiguousReserveStore{Store: backing}
	srv := NewServer(registry.New(logger), ambiguous, ServerConfig{}, logger)
	if err := backing.SetModelPrice("provider-account", "model", 1_000_000, 1_000_000); err != nil {
		t.Fatal(err)
	}
	provider := srv.registry.Register("topup-provider", nil, &protocol.RegisterMessage{
		Models: []protocol.ModelInfo{{ID: "model", ModelType: "chat", Quantization: "4bit"}},
	})
	provider.Mu().Lock()
	provider.AccountID = "provider-account"
	provider.Mu().Unlock()
	pr := &registry.PendingRequest{
		RequestID: "topup-attempt", ReservationID: "topup-base",
		ProviderID: provider.ID, Model: "model", ConsumerKey: accountID,
		EstimatedPromptTokens: 1000, RequestedMaxTokens: 1000,
		ReservedMicroUSD: 100, ReservedWithdrawableMicroUSD: baseWithdrawable,
		BaseReservedMicroUSD: 100, BaseReservedWithdrawableMicroUSD: baseWithdrawable,
	}
	required, err := srv.reserveAdditionalForProvider(pr, provider)
	if err != nil {
		t.Fatal(err)
	}
	if ambiguous.attempts != 2 || required <= 100 {
		t.Fatalf("top-up attempts=%d required=%d", ambiguous.attempts, required)
	}
	srv.refundProviderExtra(pr)
	if pr.ReservedMicroUSD != 100 ||
		pr.ReservedWithdrawableMicroUSD != baseWithdrawable {
		t.Fatalf("top-up refund left reservation %+v", pr)
	}
}

func TestServiceReservationRefundReleasesHoldWithoutCredit(t *testing.T) {
	srv, st := newReservationTestServer(t, ServerConfig{ServiceReservations: true}, nil)
	createServiceUser(t, st, "svc-refund")
	if err := st.Credit("svc-refund", 1_000_000, store.LedgerDeposit, "seed"); err != nil {
		t.Fatal(err)
	}
	serviceMode, _, err := srv.reserveInitialBalance("svc-refund", "model", 250_000, "reserve-svc-refund")
	if err != nil || !serviceMode {
		t.Fatalf("reserve serviceMode=%v err=%v", serviceMode, err)
	}

	pr := &registry.PendingRequest{RequestID: "svc-refund", Model: "model", ConsumerKey: "svc-refund", ReservedMicroUSD: 250_000, ServiceReservation: true}
	if !srv.refundReservedBalance(pr, "test") {
		t.Fatal("refundReservedBalance returned false")
	}
	if got := st.GetBalance("svc-refund"); got != 1_000_000 {
		t.Fatalf("balance = %d, want unchanged 1000000", got)
	}
	if srv.refundReservedBalance(pr, "test-again") {
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
	serviceMode, _, err := srv.reserveInitialBalance("svc-complete", "svc-model", 500_000, "reserve-svc-complete")
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
		ChunkCh:            make(chan string, 1),
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

func TestServiceReservationCannotSettleAboveFundedHold(t *testing.T) {
	srv, st := newReservationTestServer(t, ServerConfig{ServiceReservations: true}, nil)
	createServiceUser(t, st, "svc-funded-cap")
	if err := st.Credit("svc-funded-cap", 1_000_000, store.LedgerDeposit, "seed"); err != nil {
		t.Fatal(err)
	}
	if err := st.SetModelPrice("platform", "svc-cap-model", 10_000_000, 20_000_000); err != nil {
		t.Fatal(err)
	}
	const hold int64 = 100_000
	serviceMode, _, err := srv.reserveInitialBalance(
		"svc-funded-cap", "svc-cap-model", hold, "reserve-svc-cap",
	)
	if err != nil || !serviceMode {
		t.Fatalf("reserve serviceMode=%v err=%v", serviceMode, err)
	}
	provider := srv.registry.Register("svc-cap-provider", nil, &protocol.RegisterMessage{
		Models: []protocol.ModelInfo{{ID: "svc-cap-model", ModelType: "chat", Quantization: "4bit"}},
	})
	provider.Mu().Lock()
	provider.AccountID = "svc-cap-provider-account"
	provider.Mu().Unlock()
	pr := &registry.PendingRequest{
		RequestID: "svc-cap-attempt", Model: "svc-cap-model", ConsumerKey: "svc-funded-cap",
		ReservedMicroUSD: hold, ServiceReservation: true,
		ChunkCh: make(chan string, 1), CompleteCh: make(chan protocol.UsageInfo, 1),
		ErrorCh: make(chan protocol.InferenceErrorMessage, 1),
	}
	provider.AddPending(pr)
	srv.handleComplete(provider.ID, provider, &protocol.InferenceCompleteMessage{
		Type: protocol.TypeInferenceComplete, RequestID: pr.RequestID,
		Usage: protocol.UsageInfo{PromptTokens: 100_000, CompletionTokens: 100_000},
	})
	if balance := st.GetBalance("svc-funded-cap"); balance != 1_000_000-hold {
		t.Fatalf("service balance = %d, want funded cap %d", balance, 1_000_000-hold)
	}
	if payout := st.GetWithdrawableBalance("svc-cap-provider-account"); payout != hold {
		t.Fatalf("provider payout = %d, want funded cap %d", payout, hold)
	}
}
