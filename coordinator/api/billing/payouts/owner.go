// Package payouts owns Connect and Global Payouts HTTP workflows and recovery.
package payouts

import (
	"log/slog"

	"github.com/eigeninference/d-inference/coordinator/billing"
)

type Owner struct {
	billing *billing.Service
	logger  *slog.Logger
}

func New(service *billing.Service, logger *slog.Logger) *Owner {
	return &Owner{billing: service, logger: logger}
}

// SetService is called during application assembly, before serving requests.
func (s *Owner) SetService(service *billing.Service) { s.billing = service }
