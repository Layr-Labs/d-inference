// Package reservations owns monetary admission and exactly-once hold release.
package reservations

import (
	"context"
	"log/slog"
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/api/observation"
	"github.com/eigeninference/d-inference/coordinator/billing"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/promotions"
	"github.com/eigeninference/d-inference/coordinator/payments"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type Params struct {
	Model                 string
	PublicModel           string
	BillingPromptTokens   int
	EstimatedPromptTokens int
	RequestedMaxTokens    int
	Stream                bool
	RequiresVision        bool
	HasTools              bool
	SelfRoute             bool
}

func (p Params) Promotion() promotions.Admission {
	return promotions.Admission{Model: p.Model, PublicModel: p.PublicModel, BillingPromptTokens: p.BillingPromptTokens, EstimatedPromptTokens: p.EstimatedPromptTokens, RequestedMaxTokens: p.RequestedMaxTokens}
}

type Dependencies struct {
	Store       store.Store
	Ledger      *payments.Ledger
	Observation *observation.Owner
	Logger      *slog.Logger
	Billing     *billing.Service
	Promotions  *promotions.Engine
	IsService   func(string) bool
	KeyCap      func(context.Context, int64) (string, bool)
	Unavailable func(http.ResponseWriter, string)
	Reject      func(*http.Request, map[string]any, Params, string)
}

type Controller struct {
	store               store.Store
	ledger              *payments.Ledger
	observation         *observation.Owner
	logger              *slog.Logger
	billing             *billing.Service
	promotions          *promotions.Engine
	serviceReservations *serviceReservationManager
	isService           func(string) bool
	keyCap              func(context.Context, int64) (string, bool)
	unavailable         func(http.ResponseWriter, string)
	reject              func(*http.Request, map[string]any, Params, string)
}

// Bind retains the owner's actual accounting collaborators before requests run.
func (s *Controller) Bind(d Dependencies, serviceReservations bool) {
	s.store, s.ledger, s.observation, s.logger = d.Store, d.Ledger, d.Observation, d.Logger
	s.billing, s.promotions = d.Billing, d.Promotions
	s.isService, s.keyCap, s.unavailable, s.reject = d.IsService, d.KeyCap, d.Unavailable, d.Reject
	s.serviceReservations = newServiceReservationManager(d.Store, serviceReservations)
}

func (s *Controller) SetBilling(service *billing.Service) { s.billing = service }

func (s *Controller) Cost(model string, promptTokens, maxTokens int) int64 {
	return payments.RatesFor(s.store.GetModelPrice("platform", model)).CostWithMinimum(
		payments.Usage{PromptTokens: promptTokens, CompletionTokens: maxTokens})
}
