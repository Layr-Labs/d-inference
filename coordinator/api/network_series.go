package api

import (
	"encoding/json"
	"net/http"
	"time"
)

type networkSeriesWindow struct {
	label      string
	duration   time.Duration
	bucketSize time.Duration
}

func parseNetworkSeriesWindow(value string) (networkSeriesWindow, bool) {
	switch value {
	case "", "30m":
		return networkSeriesWindow{label: "30m", duration: 30 * time.Minute, bucketSize: time.Minute}, true
	case "24h", "1d":
		return networkSeriesWindow{label: "24h", duration: 24 * time.Hour, bucketSize: 30 * time.Minute}, true
	case "7d":
		return networkSeriesWindow{label: "7d", duration: 7 * 24 * time.Hour, bucketSize: 4 * time.Hour}, true
	case "30d":
		return networkSeriesWindow{label: "30d", duration: 30 * 24 * time.Hour, bucketSize: 12 * time.Hour}, true
	default:
		return networkSeriesWindow{}, false
	}
}

// handleNetworkSeries returns a bounded, complete-bucket traffic series.
// Bucket widths grow with the selected range so the payload remains compact
// and every chart presents roughly 42-60 points instead of tens of thousands.
//
// GET /v1/network/series?window=30m|24h|7d|30d
func (s *Server) handleNetworkSeries(w http.ResponseWriter, r *http.Request) {
	spec, ok := parseNetworkSeriesWindow(r.URL.Query().Get("window"))
	if !ok {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error",
			"window must be one of: 30m, 24h, 7d, 30d"))
		return
	}

	cacheKey := "network_series:" + spec.label
	if cached, ok := s.readCache.Get(cacheKey); ok {
		writeCachedJSON(w, cached)
		return
	}

	end := time.Now().UTC().Truncate(spec.bucketSize)
	start := end.Add(-spec.duration)
	buckets := s.store.UsageTimeSeries(start, spec.bucketSize)
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
		"window":         spec.label,
		"bucket_seconds": int64(spec.bucketSize / time.Second),
		"start_at":       start.Format(time.RFC3339),
		"end_at":         end.Format(time.RFC3339),
		"time_series":    timeSeries,
		"updated_at":     time.Now().UTC().Format(time.RFC3339),
	}
	body, err := json.Marshal(response)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to encode network series"))
		return
	}
	s.readCache.Set(cacheKey, body, time.Minute)
	writeCachedJSON(w, body)
}
