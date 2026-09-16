package api

import (
	"net/http"
	"sort"
)

// handleMySelfRouteModels returns the model ids a self-route(-only) key for
// this account can list and use — the same alias-aware owned live-model view
// GET /v1/models serves to self-route-only keys. The console's API-key picker
// consumes this so the ids it saves into a key's allow-list are exactly the
// ids clients will later see and request: aliases for catalog builds, raw ids
// for off-catalog local models. Deriving the list client-side from raw
// provider advertisements produced allow-lists holding hidden build ids that
// then rejected the listed alias (keyModelAllowed checks the requested name
// before alias resolution). Centralizing here also keeps the eligibility
// filter (freshness, runtime verification, private-text support, owner
// weight-hash servability) in one place instead of three.
func (s *Server) handleMySelfRouteModels(w http.ResponseWriter, r *http.Request) {
	user := s.requirePrivyUser(w, r)
	if user == nil {
		return
	}
	entries := s.catalogController().OwnedModelEntries(user.AccountID, false)
	models := make([]string, 0, len(entries))
	for _, e := range entries {
		models = append(models, e.ID)
	}
	sort.Strings(models)
	writeJSON(w, http.StatusOK, selfRouteModelsResponse{Models: models})
}

// selfRouteModelsResponse is the GET /v1/me/self-route-models payload.
type selfRouteModelsResponse struct {
	Models []string `json:"models"`
}
