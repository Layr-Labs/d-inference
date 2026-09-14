// Package settlement owns inference reservations and completion accounting.
// HTTP admission, provider terminal ownership and consumer channels remain with
// their callers. The caller supplies its existing ledger and live dependencies.
package settlement

import (
	"log/slog"

	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

type Ledger interface {
	Charge(consumerID string, amountMicroUSD int64, jobID string) error
	RecordUsage(consumerID string, entry payments.UsageEntry)
}

type Providers interface {
	GetProvider(providerID string) *registry.Provider
}

type Referral interface {
	DistributeReferralReward(consumerKey string, platformFee int64, jobID string) int64
}

type Metrics interface {
	Incr(name string, tags []string)
	Count(name string, value int64, tags []string)
	Histogram(name string, value float64, tags []string)
}

// Dependencies separates live service bindings from the single startup-owned
// service hold map. Store is resolved inside asynchronous writes as well.
type Dependencies struct {
	Store        func() Store
	Ledger       Ledger
	Providers    func() Providers
	Referral     func() Referral
	Metrics      Metrics
	Logger       *slog.Logger
	ServiceHolds *ServiceHolds
}

type Service struct{ deps Dependencies }

func New(deps Dependencies) Service { return Service{deps: deps} }
