package accounts

import (
	"net/http"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/access"
	"github.com/eigeninference/d-inference/coordinator/api/httpx"
)

func (s *Owner) HandleMyProviders(w http.ResponseWriter, r *http.Request) {
	user := access.RequirePrivyUser(w, r)
	if user == nil {
		return
	}

	fleet, err := s.mergeFleet(r.Context(), user.AccountID)
	if err != nil {
		s.logger.Error("merge fleet failed", "account_id", user.AccountID, "error", err)
		httpx.WriteJSON(w, http.StatusInternalServerError, httpx.ErrorResponse("internal_error", "failed to list providers"))
		return
	}

	s.attachStoredReputations(r.Context(), fleet)

	resp := myProvidersResponse{
		Providers:             fleet,
		LatestProviderVersion: s.latestReleasedVersion(),
		MinProviderVersion:    s.minProviderVersion,
		HeartbeatTimeoutSec:   ownerHeartbeatTimeoutSeconds,
		ChallengeMaxAgeSec:    int((6 * time.Minute).Seconds()),
	}
	httpx.WriteJSON(w, http.StatusOK, resp)
}
