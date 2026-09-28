package api

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// Fixed hourly boundaries and a one-hour delay limit differencing of sparse
// activity. No arbitrary dates, per-consumer filters, or raw diagnostics exist.
func (s *Server) handleModelDemand(w http.ResponseWriter, r *http.Request) {
	window := r.URL.Query().Get("window")
	if window == "" {
		window = "24h"
	}
	index := 0
	switch window {
	case "24h":
	case "7d":
		index = 1
	case "30d":
		index = 2
	default:
		writeJSON(w, 400, errorResponse("invalid_request_error", "window must be one of: 24h, 7d, 30d"))
		return
	}
	spec, _ := parseNetworkSeriesWindow(window)
	body, ok := s.getCachedEntry(&s.modelDemandRefresh[index], "model_demand:"+window, func() ([]byte, error) {
		backend, ok := store.As[store.ModelDemandStore](s.store)
		if !ok {
			return nil, errors.New("model demand store unavailable")
		}
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		end := time.Now().UTC().Truncate(time.Hour).Add(-time.Hour)
		start := end.Add(-spec.duration)
		snapshot, err := backend.ModelDemand(ctx, start, end)
		if err != nil {
			return nil, err
		}
		return json.Marshal(struct {
			store.ModelDemandSnapshot
			Window    string    `json:"window"`
			StartAt   time.Time `json:"start_at"`
			EndAt     time.Time `json:"end_at"`
			UpdatedAt time.Time `json:"updated_at"`
			Coverage  string    `json:"coverage"`
		}{snapshot, window, start, end, time.Now().UTC(), "published_hourly_cohorts"})
	})
	if !ok {
		writeJSON(w, 503, errorResponse("service_unavailable", "model demand is temporarily unavailable"))
		return
	}
	writeCachedJSON(w, body)
}
