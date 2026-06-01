package api

// Account-scoped provider endpoints used by the console-ui /providers dashboard.
//
// These endpoints answer "what machines does THIS user own, and are they earning?"
// by merging persisted ProviderRecord state (which survives coordinator restarts and
// includes offline machines) with the live registry.Provider snapshot (status,
// heartbeat metrics, backend capacity).
//
// Authentication is Privy-only: these are user-scoped views, not API key
// keyspaces. API keys are rejected by the route middleware.

import (
	"net/http"
	"time"
)

func (s *Server) handleMySummary(w http.ResponseWriter, r *http.Request) {
	user := s.requirePrivyUser(w, r)
	if user == nil {
		return
	}
	accountID := user.AccountID

	summary, err := s.store.GetAccountEarningsSummary(accountID)
	if err != nil {
		s.logger.Error("get account earnings summary failed", "error", err)
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to fetch earnings"))
		return
	}

	recent, err := s.store.GetAccountEarnings(accountID, 5000)
	if err != nil {
		s.logger.Error("get account earnings failed", "error", err)
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to fetch earnings"))
		return
	}
	now := time.Now()
	cutoff24h := now.Add(-24 * time.Hour)
	cutoff7d := now.Add(-7 * 24 * time.Hour)
	var last24Money, last7dMoney int64
	var last24Jobs, last7dJobs int64
	for _, e := range recent {
		if e.CreatedAt.After(cutoff7d) {
			last7dMoney += e.AmountMicroUSD
			last7dJobs++
			if e.CreatedAt.After(cutoff24h) {
				last24Money += e.AmountMicroUSD
				last24Jobs++
			}
		}
	}

	fleet, err := s.mergeFleet(r.Context(), accountID)
	if err != nil {
		s.logger.Error("merge fleet failed", "account_id", accountID, "error", err)
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to list providers"))
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
		Last24hMicroUSD:             last24Money,
		Last24hJobs:                 last24Jobs,
		Last7dMicroUSD:              last7dMoney,
		Last7dJobs:                  last7dJobs,
		Counts:                      counts,
		LatestProviderVersion:       s.latestReleasedVersion(),
		MinProviderVersion:          s.minProviderVersion,
	}
	writeJSON(w, http.StatusOK, resp)
}

func (s *Server) handleMyProviders(w http.ResponseWriter, r *http.Request) {
	user := s.requirePrivyUser(w, r)
	if user == nil {
		return
	}

	fleet, err := s.mergeFleet(r.Context(), user.AccountID)
	if err != nil {
		s.logger.Error("merge fleet failed", "account_id", user.AccountID, "error", err)
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to list providers"))
		return
	}

	for i := range fleet {
		s.attachStoredReputation(r.Context(), &fleet[i])
		s.attachEarnings(&fleet[i])
	}

	resp := myProvidersResponse{
		Providers:             fleet,
		LatestProviderVersion: s.latestReleasedVersion(),
		MinProviderVersion:    s.minProviderVersion,
		HeartbeatTimeoutSec:   90,
		ChallengeMaxAgeSec:    int((6 * time.Minute).Seconds()),
	}
	writeJSON(w, http.StatusOK, resp)
}
