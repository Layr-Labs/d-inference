// Package promotions owns durable token/cash holds and their reconciliation.
// The inference owner still selects the terminal and owns usage accounting.
package promotions

import (
	"log/slog"
	"net/http"
	"sync"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type Dependencies struct {
	Store               store.Store
	Logger              *slog.Logger
	Unavailable         func(http.ResponseWriter, string)
	IsService           func(string) bool
	ProviderPricingKeys func(*registry.Provider) string
}

type Engine struct {
	store               store.Store
	logger              *slog.Logger
	unavailable         func(http.ResponseWriter, string)
	isService           func(string) bool
	providerPricingKeys func(*registry.Provider) string
	active              sync.Map
	refunds             sync.Map
	settlements         sync.Map
}

// Bind connects a retained engine to the owning request lifecycle's actual
// collaborators before serving starts, without replacing its private queues.
func (e *Engine) Bind(d Dependencies) {
	e.store, e.logger = d.Store, d.Logger
	e.unavailable, e.isService, e.providerPricingKeys = d.Unavailable, d.IsService, d.ProviderPricingKeys
}

type Admission struct {
	Model                 string
	PublicModel           string
	BillingPromptTokens   int
	EstimatedPromptTokens int
	RequestedMaxTokens    int
}
