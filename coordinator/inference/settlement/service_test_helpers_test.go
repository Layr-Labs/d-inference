package settlement

import (
	"io"
	"log/slog"
	"sync"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

var testConsumerID = store.LegacyAccountID("test-key")

type discardMetrics struct{}

func (discardMetrics) Incr(string, []string)               {}
func (discardMetrics) Count(string, int64, []string)       {}
func (discardMetrics) Histogram(string, float64, []string) {}

func settlementTestService(t *testing.T) (Service, *store.MemoryStore, *payments.Ledger) {
	t.Helper()
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	ledger := payments.NewLedger(st)
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	providers := registry.New(logger)
	svc := New(Dependencies{
		Store: func() Store { return st }, Ledger: ledger,
		Providers: func() Providers { return providers }, Referral: func() Referral { return nil },
		Metrics: discardMetrics{}, Logger: logger, ServiceHolds: NewServiceHolds(st, false),
	})
	if err := st.Credit(testConsumerID, 100_000_000, store.LedgerDeposit, "test-setup"); err != nil {
		t.Fatal(err)
	}
	return svc, st, ledger
}

type serviceHoldCountingStore struct {
	store.Store
	mu       sync.Mutex
	debits   int
	debitErr error
}

func (s *serviceHoldCountingStore) Debit(accountID string, amountMicroUSD int64, entryType store.LedgerEntryType, reference string) error {
	s.mu.Lock()
	s.debits++
	err := s.debitErr
	s.mu.Unlock()
	if err != nil {
		return err
	}
	return s.Store.Debit(accountID, amountMicroUSD, entryType, reference)
}

func (s *serviceHoldCountingStore) DebitCount() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.debits
}

func newServiceHoldTestService(t *testing.T, debitErr error) (Service, *serviceHoldCountingStore) {
	t.Helper()
	svc, mem, _ := settlementTestService(t)
	st := &serviceHoldCountingStore{Store: mem, debitErr: debitErr}
	svc.deps.Store = func() Store { return st }
	svc.deps.Ledger = payments.NewLedger(st)
	svc.deps.ServiceHolds = NewServiceHolds(st, true)
	return svc, st
}

func createServiceUser(t *testing.T, st store.Store, accountID string) {
	t.Helper()
	if err := st.CreateUser(&store.User{AccountID: accountID, PrivyUserID: "did:privy:" + accountID, Role: store.RoleService}); err != nil {
		t.Fatal(err)
	}
}
