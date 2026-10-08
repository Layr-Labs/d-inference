package inference_test

import (
	"errors"
	"log/slog"
	"net/http"
	"os"
	"slices"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/api/inference"
	"github.com/eigeninference/d-inference/coordinator/api/readcache"
	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/promotions"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/reservations"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

type TestServerConfig = api.ServerConfig

// This injected store retains the real backend. Only settlement acknowledgements
// are faulted, and renewal calls are observed at the actual persistence boundary.
type promotionStore struct {
	store.Store
	store.ModelTokenPromotionStore
	mu            sync.Mutex
	settlement    store.ModelTokenPromotionStore
	renewed       []string
	creditFailure atomic.Bool
}

func (s *promotionStore) Credit(accountID string, amount int64, entryType store.LedgerEntryType, reference string) error {
	if s.creditFailure.Load() {
		return errors.New("forced credit failure")
	}
	return s.Store.Credit(accountID, amount, entryType, reference)
}

func (s *promotionStore) useSettlement(backend store.ModelTokenPromotionStore) {
	s.mu.Lock()
	s.settlement = backend
	s.mu.Unlock()
}

func (s *promotionStore) SettleModelTokenReservation(id string, actual int64, quote store.ModelTokenQuote, earning *store.ModelTokenEarning, referralEligible bool) (store.ModelTokenSettlement, error) {
	s.mu.Lock()
	backend := s.settlement
	s.mu.Unlock()
	return backend.SettleModelTokenReservation(id, actual, quote, earning, referralEligible)
}

func (s *promotionStore) RenewModelTokenReservations(ids []string, at time.Time) error {
	s.mu.Lock()
	s.renewed = slices.Clone(ids)
	s.mu.Unlock()
	return s.ModelTokenPromotionStore.RenewModelTokenReservations(ids, at)
}

func (s *promotionStore) renewing(id string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return slices.Contains(s.renewed, id)
}

type reservationFixture struct {
	*inference.Owner
	server       *api.Server
	registry     *registry.Registry
	store        store.Store
	ledger       *payments.Ledger
	billing      *billing.Service
	promotions   *promotions.Engine
	reservations *reservations.Controller
	fault        *promotionStore
}

func newComposedServer(reg *registry.Registry, st store.Store, cfg TestServerConfig, logger *slog.Logger) *reservationFixture {
	ledger := payments.NewLedger(st)
	engine := &promotions.Engine{}
	holds := &reservations.Controller{}
	runtime := api.NewRuntime(api.RuntimeDependencies{Registry: reg, Store: st, Ledger: ledger, ReadCache: readcache.New(), Logger: logger, InferencePromotions: engine, InferenceReservations: holds}, cfg)
	return &reservationFixture{Owner: runtime.Server.Inference(), server: runtime.Server, registry: reg, store: st, ledger: ledger, promotions: engine, reservations: holds}
}

func (s *reservationFixture) Close()                { s.server.Close() }
func (s *reservationFixture) Handler() http.Handler { return s.server.Handler() }
func (s *reservationFixture) bindBilling(service *billing.Service) {
	s.billing = service
	s.server.SetBilling(service)
}
func (s *reservationFixture) handleComplete(id string, provider *registry.Provider, msg *protocol.InferenceCompleteMessage) {
	s.Owner.HandleCompleteAt(id, provider, msg, time.Now())
}

func billingTestServer(t *testing.T) (*reservationFixture, *memory.MemoryStore, *payments.Ledger) {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	mem := memory.NewMemory(store.Config{AdminKey: "test-key"})
	fault := &promotionStore{Store: mem, ModelTokenPromotionStore: mem, settlement: mem}
	s := newComposedServer(registry.New(logger), store.NewCached(fault, store.CacheConfig{}), TestServerConfig{}, logger)
	s.fault = fault
	s.server.SetChallengeInterval(200 * time.Millisecond)
	s.bindBilling(billing.NewService(s.store, s.ledger, logger, billing.Config{MockMode: true}))
	_ = mem.Credit(store.LegacyAccountID("test-key"), 100_000_000, store.LedgerDeposit, "test-setup")
	return s, mem, s.ledger
}

func awaitUsageRows(t *testing.T, st *memory.MemoryStore, consumerID string) []store.UsageRecord {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if len(st.UsageByConsumer(consumerID)) > 0 {
			return st.UsageByConsumer(consumerID)
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal("usage row was not persisted")
	return nil
}
