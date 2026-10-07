package observation

import (
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/api/access"
	"github.com/eigeninference/d-inference/coordinator/internal/observation/outcomes"
)

// Scope once, after account gates and body preparation, before any capacity
// rejection. Exclude owner-preferred and machine-restricted traffic as well as
// exclusive self-route; their demand is not interchangeable with public supply.
func MarkPublicModelDemand(r *http.Request, selfRouteOnly, preferOwner bool, allowedProviderSerials []string, publicModel, modelID string) {
	consumer := access.ConsumerKeyFromContext(r.Context())
	scope := outcomes.PublicScope(consumer, selfRouteOnly, preferOwner, allowedProviderSerials, publicModel, modelID)
	if scope == nil {
		return
	}
	if o := requestOutcomeFromContext(r.Context()); o != nil {
		o.mu.Lock()
		defer o.mu.Unlock()
		o.record.PublicDemand = scope
		o.publishLocked()
	}
}
