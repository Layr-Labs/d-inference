package reporting

import (
	"encoding/json"
	"net/http"
	"time"

	httpx "github.com/eigeninference/d-inference/coordinator/api/httpx"
	windows "github.com/eigeninference/d-inference/coordinator/internal/api/reporting/windows"
)

// handleNetworkSeries returns a bounded, complete-bucket traffic series.
// Bucket widths grow with the selected range so the payload remains compact
// and every chart presents roughly 42-60 points instead of tens of thousands.
//
// GET /v1/network/series?window=30m|24h|7d|30d
func (s *Owner) HandleNetworkSeries(w http.ResponseWriter, r *http.Request) {
	spec, ok := windows.ParseNetworkSeriesWindow(r.URL.Query().Get("window"))
	if !ok {
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error",
			"window must be one of: 30m, 24h, 7d, 30d"))
		return
	}
	if spec.Duration > windows.MaxNetworkSeriesLookback {
		httpx.WriteJSON(w, http.StatusBadRequest, httpx.ErrorResponse("invalid_request_error",
			"network series lookback exceeds 30 days"))
		return
	}

	cacheKey := "network_series:" + spec.Label
	if s.analyticsSnapshotPath != "" {
		s.archivedNetworkSeries(w, spec.Label)
		return
	}
	if cached, ok := s.readCache.Get(cacheKey); ok {
		httpx.WriteCachedJSON(w, cached)
		return
	}

	end := time.Now().UTC().Truncate(spec.BucketSize)
	start := end.Add(-spec.Duration)
	buckets, err := s.store.UsageTimeSeries(start, end, spec.BucketSize)
	if err != nil {
		// Never cache or serve an empty series for a statement that did not
		// complete; the next request retries.
		s.logger.Warn("network series unavailable", "window", spec.Label, "error", err)
		httpx.WriteJSON(w, http.StatusServiceUnavailable, httpx.ErrorResponse("service_unavailable", "network series is temporarily unavailable"))
		return
	}
	timeSeries := make([]map[string]any, 0, len(buckets))
	for _, bucket := range buckets {
		if !bucket.Minute.Before(end) {
			continue
		}
		timeSeries = append(timeSeries, map[string]any{
			"timestamp":         bucket.Minute.UTC().Format(time.RFC3339),
			"requests":          bucket.Requests,
			"prompt_tokens":     bucket.PromptTokens,
			"completion_tokens": bucket.CompletionTokens,
		})
	}

	response := map[string]any{
		"window":         spec.Label,
		"bucket_seconds": int64(spec.BucketSize / time.Second),
		"start_at":       start.Format(time.RFC3339),
		"end_at":         end.Format(time.RFC3339),
		"time_series":    timeSeries,
		"updated_at":     time.Now().UTC().Format(time.RFC3339),
	}
	body, err := json.Marshal(response)
	if err != nil {
		httpx.WriteJSON(w, http.StatusInternalServerError, httpx.ErrorResponse("internal_error", "failed to encode network series"))
		return
	}
	s.readCache.Set(cacheKey, body, 5*time.Minute)
	httpx.WriteCachedJSON(w, body)
}
