package payoutrecovery

import (
	"log/slog"

	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// recoveryState applies persisted payout outcomes independently of HTTP delivery.
type Reconciler struct {
	billing *billing.Service
	logger  *slog.Logger
}

func New(service *billing.Service, logger *slog.Logger) *Reconciler {
	return &Reconciler{billing: service, logger: logger}
}

func Store(service *billing.Service) (store.GlobalPayoutStore, bool) {
	if service == nil {
		return nil, false
	}
	return store.As[store.GlobalPayoutStore](service.Store())
}
