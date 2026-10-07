// Package billing owns billing HTTP contracts without owning a second ledger.
package billing

import (
	"log/slog"
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/api/readcache"
	billingservice "github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/payments/baserewards"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type Store interface {
	store.LedgerStore
	GetUserByEmail(string) (*store.User, error)
	UsageByConsumer(string) []store.UsageRecord
	SetModelPrice(store.ModelPrice) error
	ListModelPrices(string) []store.ModelPrice
	DeleteModelPrice(string, string) error
	GetAccountEarnings(string, int) ([]store.ProviderEarning, error)
	GetAccountEarningsSummary(string) (store.ProviderEarningsSummary, error)
}

type Authorizer interface {
	IsAdminAuthorized(http.ResponseWriter, *http.Request) bool
}

type Dependencies struct {
	Store           Store
	Ledger          *payments.Ledger
	Service         *billingservice.Service
	Access          Authorizer
	Logger          *slog.Logger
	ReadCache       *readcache.Cache
	IncrementMetric func(string, []string)
}

type Owner struct {
	store       Store
	ledger      *payments.Ledger
	billing     *billingservice.Service
	baseRewards *baserewards.Engine
	access      Authorizer
	logger      *slog.Logger
	readCache   *readcache.Cache
	ddIncr      func(string, []string)
}

func New(d Dependencies) *Owner {
	if d.IncrementMetric == nil {
		d.IncrementMetric = func(string, []string) {}
	}
	return &Owner{store: d.Store, ledger: d.Ledger, billing: d.Service, access: d.Access,
		logger: d.Logger, readCache: d.ReadCache, ddIncr: d.IncrementMetric}
}

// SetService is called during application assembly, before serving requests.
func (s *Owner) SetService(service *billingservice.Service) { s.billing = service }
func (s *Owner) SetBaseRewards(engine *baserewards.Engine)  { s.baseRewards = engine }
