package accountfleet

import (
	"net/http"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/httpresponse"
)

type providersResponse struct {
	Providers             []providerView `json:"providers"`
	LatestProviderVersion string         `json:"latest_provider_version"`
	MinProviderVersion    string         `json:"min_provider_version"`
	HeartbeatTimeoutSec   int            `json:"heartbeat_timeout_seconds"`
	ChallengeMaxAgeSec    int            `json:"challenge_max_age_seconds"`
}

func (s *Controller) Providers(w http.ResponseWriter, r *http.Request) {
	user := s.requireUser(w, r)
	if user == nil {
		return
	}

	fleet, err := s.mergeFleet(r.Context(), user.AccountID)
	if err != nil {
		s.logger.Error("merge fleet failed", "account_id", user.AccountID, "error", err)
		httpresponse.WriteJSON(w, http.StatusInternalServerError, httpresponse.ErrorBody("internal_error", "failed to list providers"))
		return
	}

	s.attachStoredReputations(r.Context(), fleet)

	resp := providersResponse{
		Providers:             fleet,
		LatestProviderVersion: s.latestVersion(),
		MinProviderVersion:    s.minVersion(),
		HeartbeatTimeoutSec:   90,
		ChallengeMaxAgeSec:    int((6 * time.Minute).Seconds()),
	}
	httpresponse.WriteJSON(w, http.StatusOK, resp)
}
