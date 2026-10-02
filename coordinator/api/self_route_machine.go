package api

import (
	"net/http"
	"strings"
)

const selfRouteMachineHeader = "X-Darkbloom-Machine"

// resolveSelfRouteMachine validates an optional opaque provider session id.
// Ownership remains enforced by the scheduler at reservation time too.
func (s *Server) resolveSelfRouteMachine(w http.ResponseWriter, r *http.Request, policy selfRoutePolicy) (selfRoutePolicy, bool) {
	values := r.Header.Values(selfRouteMachineHeader)
	if len(values) == 0 {
		return policy, true
	}
	id := strings.TrimSpace(values[0])
	if len(values) != 1 || id == "" || len(id) > 256 || strings.Contains(id, ",") || !policy.enabled {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error",
			"X-Darkbloom-Machine requires one provider id and exclusive self-routing (X-Darkbloom-Route: self or a self_route_only key)",
			withParam(selfRouteMachineHeader)))
		return policy, false
	}

	owner := ""
	if p := s.registry.GetProvider(id); p != nil {
		p.Mu().Lock()
		owner = p.AccountID
		p.Mu().Unlock()
	} else {
		records, err := s.store.ListProvidersByAccount(r.Context(), policy.ownerAccountID)
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to look up machine"))
			return policy, false
		}
		for _, rec := range records {
			if rec.ID == id {
				owner = rec.AccountID
				break
			}
		}
	}
	// Use the same response for unknown and unowned ids to avoid disclosing
	// whether another account's private provider exists.
	if owner == "" || owner != policy.ownerAccountID {
		writeJSON(w, http.StatusNotFound, errorResponse("machine_not_found",
			"selected machine not found on your account", withParam(selfRouteMachineHeader)))
		return policy, false
	}
	policy.providerID = id
	return policy, true
}
