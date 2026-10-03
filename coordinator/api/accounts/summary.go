package accounts

import (
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/api/access"
	"github.com/eigeninference/d-inference/coordinator/api/httpx"
)

func (s *Owner) HandleMySummary(w http.ResponseWriter, r *http.Request) {
	user := access.RequirePrivyUser(w, r)
	if user == nil {
		return
	}
	accountID := user.AccountID

	summary, err := s.store.GetAccountEarningsSummary(accountID)
	if err != nil {
		s.logger.Error("get account earnings summary failed", "error", err)
		httpx.WriteJSON(w, http.StatusInternalServerError, httpx.ErrorResponse("internal_error", "failed to fetch earnings"))
		return
	}

	windows, err := s.accountEarningsWindows(accountID)
	if err != nil {
		s.logger.Error("get account earnings windows failed", "error", err)
		httpx.WriteJSON(w, http.StatusInternalServerError, httpx.ErrorResponse("internal_error", "failed to fetch earnings"))
		return
	}

	fleet, err := s.mergeFleet(r.Context(), accountID)
	if err != nil {
		s.logger.Error("merge fleet failed", "account_id", accountID, "error", err)
		httpx.WriteJSON(w, http.StatusInternalServerError, httpx.ErrorResponse("internal_error", "failed to list providers"))
		return
	}

	counts := myFleetCounts{}
	for i := range fleet {
		tallyCounts(&counts, &fleet[i], s.minProviderVersion)
	}

	resp := mySummaryResponse{
		AccountID:                   accountID,
		AvailableBalanceMicroUSD:    s.store.GetBalance(accountID),
		WithdrawableBalanceMicroUSD: s.store.GetWithdrawableBalance(accountID),
		PayoutReady:                 user.StripeAccountStatus == "ready",
		LifetimeMicroUSD:            summary.TotalMicroUSD,
		LifetimeJobs:                summary.Count,
		Last24hMicroUSD:             windows.Last24hMicroUSD,
		Last24hJobs:                 windows.Last24hJobs,
		Last7dMicroUSD:              windows.Last7dMicroUSD,
		Last7dJobs:                  windows.Last7dJobs,
		Counts:                      counts,
		LatestProviderVersion:       s.latestReleasedVersion(),
		MinProviderVersion:          s.minProviderVersion,
	}
	httpx.WriteJSON(w, http.StatusOK, resp)
}
