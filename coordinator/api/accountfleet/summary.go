package accountfleet

import (
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/api/httpresponse"
)

// summaryResponse is the page-level dashboard header at /v1/me/summary.
type summaryResponse struct {
	AccountID                   string      `json:"account_id"`
	AvailableBalanceMicroUSD    int64       `json:"available_balance_micro_usd"`
	WithdrawableBalanceMicroUSD int64       `json:"withdrawable_balance_micro_usd"`
	PayoutReady                 bool        `json:"payout_ready"`
	LifetimeMicroUSD            int64       `json:"lifetime_micro_usd"`
	LifetimeJobs                int64       `json:"lifetime_jobs"`
	Last24hMicroUSD             int64       `json:"last_24h_micro_usd"`
	Last24hJobs                 int64       `json:"last_24h_jobs"`
	Last7dMicroUSD              int64       `json:"last_7d_micro_usd"`
	Last7dJobs                  int64       `json:"last_7d_jobs"`
	Counts                      fleetCounts `json:"counts"`
	LatestProviderVersion       string      `json:"latest_provider_version"`
	MinProviderVersion          string      `json:"min_provider_version"`
}

func (s *Controller) Summary(w http.ResponseWriter, r *http.Request) {
	user := s.requireUser(w, r)
	if user == nil {
		return
	}
	accountID := user.AccountID

	summary, err := s.store().GetAccountEarningsSummary(accountID)
	if err != nil {
		s.logger.Error("get account earnings summary failed", "error", err)
		httpresponse.WriteJSON(w, http.StatusInternalServerError, httpresponse.ErrorBody("internal_error", "failed to fetch earnings"))
		return
	}

	windows, err := s.accountEarningsWindows(accountID)
	if err != nil {
		s.logger.Error("get account earnings windows failed", "error", err)
		httpresponse.WriteJSON(w, http.StatusInternalServerError, httpresponse.ErrorBody("internal_error", "failed to fetch earnings"))
		return
	}

	fleet, err := s.mergeFleet(r.Context(), accountID)
	if err != nil {
		s.logger.Error("merge fleet failed", "account_id", accountID, "error", err)
		httpresponse.WriteJSON(w, http.StatusInternalServerError, httpresponse.ErrorBody("internal_error", "failed to list providers"))
		return
	}

	counts := fleetCounts{}
	for i := range fleet {
		s.tallyCounts(&counts, &fleet[i], s.minVersion())
	}

	resp := summaryResponse{
		AccountID:                   accountID,
		AvailableBalanceMicroUSD:    s.store().GetBalance(accountID),
		WithdrawableBalanceMicroUSD: s.store().GetWithdrawableBalance(accountID),
		PayoutReady:                 user.StripeAccountStatus == "ready",
		LifetimeMicroUSD:            summary.TotalMicroUSD,
		LifetimeJobs:                summary.Count,
		Last24hMicroUSD:             windows.Last24hMicroUSD,
		Last24hJobs:                 windows.Last24hJobs,
		Last7dMicroUSD:              windows.Last7dMicroUSD,
		Last7dJobs:                  windows.Last7dJobs,
		Counts:                      counts,
		LatestProviderVersion:       s.latestVersion(),
		MinProviderVersion:          s.minVersion(),
	}
	httpresponse.WriteJSON(w, http.StatusOK, resp)
}
