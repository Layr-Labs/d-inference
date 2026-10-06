package catalog

import (
	"encoding/json"
	"net/http"
	"time"

	httpx "github.com/eigeninference/d-inference/coordinator/api/httpx"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// modelsCapacityResponse is the GET /v1/models/capacity response body. Draining
// is omitted during normal operation so the healthy response is byte-identical to
// before; it is set true only while the coordinator is draining (empty Models).
type modelsCapacityResponse struct {
	Models   []registry.ModelCapacity `json:"models"`
	Draining bool                     `json:"draining,omitempty"`
}

// HandleModelsCapacity handles GET /v1/models/capacity.
//
// Returns a live capacity snapshot for every model served by at least one
// routable provider. Designed for upstream routers (e.g. OpenRouter) to poll
// before dispatching requests. No authentication required.
func (s *Owner) HandleModelsCapacity(w http.ResponseWriter, r *http.Request) {
	// While draining for a restart/upgrade, advertise zero capacity / not-ready so
	// OpenRouter-style routers stop selecting this instance instead of dispatching
	// here and then getting drain-gate 429s. Checked BEFORE the cache so a pre-drain
	// snapshot can't keep advertising capacity, and intentionally NOT cached so an
	// un-drain (rollback) is reflected on the very next poll.
	if s.hooks.IsDraining != nil && s.hooks.IsDraining() {
		httpx.WriteJSON(w, http.StatusOK, modelsCapacityResponse{
			Models:   []registry.ModelCapacity{},
			Draining: true,
		})
		return
	}

	const cacheKey = "models_capacity:v1"
	if cached, ok := s.readCache.Get(cacheKey); ok {
		httpx.WriteCachedJSON(w, cached)
		return
	}

	capacities := s.registry.ModelCapacitySnapshot()

	resp := modelsCapacityResponse{
		Models: capacities,
	}

	body, err := json.Marshal(resp)
	if err != nil {
		httpx.WriteJSON(w, http.StatusInternalServerError, httpx.ErrorResponse("internal_error", "failed to encode capacity"))
		return
	}
	// Cache for 2 seconds — capacity data changes frequently but the
	// endpoint may be polled aggressively by upstream routers.
	s.readCache.Set(cacheKey, body, 2*time.Second)
	httpx.WriteCachedJSON(w, body)
}
