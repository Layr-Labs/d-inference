package reporting

import (
	"context"
	"net/http"
	"time"

	"github.com/eigeninference/d-inference/coordinator/analyticssnapshot"
	"github.com/eigeninference/d-inference/coordinator/api/httpx"
	"github.com/eigeninference/d-inference/coordinator/saferun"
)

func (s *Owner) startAnalyticsSnapshots(ctx context.Context) {
	if s.analyticsSnapshotPath == "" {
		return
	}
	saferun.Go(s.logger, "api.analyticsSnapshots", func() {
		refresh := func() {
			if err := s.analyticsSnapshot.Load(s.analyticsSnapshotPath, time.Now()); err != nil && s.logger != nil {
				s.logger.Warn("analytics snapshot refresh failed", "error", err)
				s.ddIncr("cache.refresh_failed", []string{"key:archive_analytics"})
			}
		}
		refresh()
		ticker := time.NewTicker(analyticssnapshot.RefreshInterval)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				refresh()
			}
		}
	})
}

func analyticsUnavailable(w http.ResponseWriter) {
	httpx.WriteJSON(w, http.StatusServiceUnavailable, httpx.ErrorResponse("service_unavailable", "analytics are temporarily unavailable"))
}

func (s *Owner) archivedNetworkTotals(w http.ResponseWriter, window string) {
	snapshot, ok := s.analyticsSnapshot.Get(time.Now())
	if !ok {
		analyticsUnavailable(w)
		return
	}
	t := snapshot.Windows[window].Totals
	httpx.WriteJSON(w, http.StatusOK, map[string]any{
		"window": window, "earnings_micro_usd": t.EarningsMicroUSD,
		"work_earnings_micro_usd": t.WorkEarningsMicroUSD, "reward_earnings_micro_usd": t.RewardEarningsMicroUSD,
		"tokens": t.Tokens, "jobs": t.Jobs, "active_accounts": t.ActiveAccounts,
		"updated_at": snapshot.AsOf.UTC().Format(time.RFC3339),
	})
}

func (s *Owner) archivedNetworkSeries(w http.ResponseWriter, window string) {
	snapshot, ok := s.analyticsSnapshot.Get(time.Now())
	if !ok {
		analyticsUnavailable(w)
		return
	}
	series := snapshot.Series[window]
	buckets := make([]map[string]any, 0, len(series.Buckets))
	for _, b := range series.Buckets {
		buckets = append(buckets, map[string]any{"timestamp": b.Minute.UTC().Format(time.RFC3339), "requests": b.Requests, "prompt_tokens": b.PromptTokens, "completion_tokens": b.CompletionTokens})
	}
	httpx.WriteJSON(w, http.StatusOK, map[string]any{"window": window, "bucket_seconds": series.BucketSeconds, "start_at": series.Start.UTC().Format(time.RFC3339), "end_at": series.End.UTC().Format(time.RFC3339), "time_series": buckets, "updated_at": snapshot.AsOf.UTC().Format(time.RFC3339)})
}
