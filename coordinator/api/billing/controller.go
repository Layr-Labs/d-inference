// Package billing owns billing, referral, pricing, earnings and payout HTTP
// controllers. Financial services and durable ledger transitions remain in
// coordinator/billing, payments and store.
package billing

import (
	"log/slog"
	"net/http"
	"time"

	billingservice "github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/payments/baserewards"
)

// ByteCache is the shared cache of serialized read responses.
// Implementations own synchronization and expiry; controllers retain no cache state.
type ByteCache interface {
	Get(string) ([]byte, bool)
	Set(string, []byte, time.Duration)
}

// Metrics records the existing billing failure counters.
type Metrics interface {
	Incr(string, []string)
}

// Dependencies connects the HTTP controller to existing services. Service and
// BaseRewards are getters because configuration can be installed or replaced
// after routes are registered. They must be supplied even when they return nil.
// AuthorizeAdmin uses the router's current authentication policy and writes its
// rejection response. Store, Logger and Cache are shared with the router.
type Dependencies struct {
	Store          Store
	Service        func() *billingservice.Service
	BaseRewards    func() *baserewards.Engine
	Logger         *slog.Logger
	Cache          ByteCache
	Metrics        Metrics
	AuthorizeAdmin func(http.ResponseWriter, *http.Request) bool
}

// Controller holds endpoint dependencies without owning a second billing
// service, ledger, auth configuration or reconciliation store.
type Controller struct {
	store          Store
	billing        func() *billingservice.Service
	baseRewards    func() *baserewards.Engine
	logger         *slog.Logger
	readCache      ByteCache
	metrics        Metrics
	authorizeAdmin func(http.ResponseWriter, *http.Request) bool
}

// New binds endpoint dependencies without copying mutable service configuration.
func New(deps Dependencies) *Controller {
	return &Controller{
		store: deps.Store, billing: deps.Service, baseRewards: deps.BaseRewards,
		logger: deps.Logger, readCache: deps.Cache, metrics: deps.Metrics,
		authorizeAdmin: deps.AuthorizeAdmin,
	}
}

func (s *Controller) recordMetric(name string, tags []string) {
	if s.metrics != nil {
		s.metrics.Incr(name, tags)
	}
}
