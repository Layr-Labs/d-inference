package api

import (
	"net/http"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

// handleModelsCapacity handles GET /v1/models/capacity.
//
// Returns a live capacity snapshot for every model served by at least one
// routable provider. Designed for upstream routers (e.g. OpenRouter) to poll
// before dispatching requests. No authentication required.
func (s *Server) handleModelsCapacity(w http.ResponseWriter, r *http.Request) {
	const cacheKey = "models_capacity:v1"
	if cached, ok := s.readCache.Get(cacheKey); ok {
		writeCachedJSON(w, cached)
		return
	}

	capacities := s.registry.ModelCapacitySnapshot()

	resp := struct {
		Models []registry.ModelCapacity `json:"models"`
	}{
		Models: capacities,
	}

	// Cache for 2 seconds — capacity data changes frequently but the
	// endpoint may be polled aggressively by upstream routers.
	s.writeCachedJSONResult(w, cacheKey, 2*time.Second, resp, "failed to encode capacity")
}
