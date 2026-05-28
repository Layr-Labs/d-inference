package api

import (
	"context"
	"math"
	"net/http"
	"sort"
	"strconv"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// Liveness analytics endpoints. Admin-gated, internal-only — these expose
// the rollup data produced by coordinator/liveness/{writer,session,features,hourly}
// for dashboards and future job-aware scheduling.
//
// Provider IDs are returned raw, matching the existing /v1/stats convention.
// If pseudonymization is ever needed, add it at the response-serialization
// layer; we don't pre-emptively complicate the path.

const (
	livenessDefaultLimit = 50
	livenessMaxLimit     = 500
)

// parseLivenessWindow accepts "24h", "7d", "30d". Empty defaults to 7d.
// Returns (duration, ok).
func parseLivenessWindow(s string) (time.Duration, bool) {
	switch s {
	case "", "7d":
		return 7 * 24 * time.Hour, true
	case "24h", "1d":
		return 24 * time.Hour, true
	case "30d":
		return 30 * 24 * time.Hour, true
	}
	return 0, false
}

func parseLivenessLimit(raw string) int {
	if raw == "" {
		return livenessDefaultLimit
	}
	v, err := strconv.Atoi(raw)
	if err != nil || v <= 0 {
		return livenessDefaultLimit
	}
	if v > livenessMaxLimit {
		return livenessMaxLimit
	}
	return v
}

func parseUnitFloat(raw string) float64 {
	if raw == "" {
		return 0
	}
	v, err := strconv.ParseFloat(raw, 64)
	if err != nil || v < 0 {
		return 0
	}
	if v > 1 {
		return 1
	}
	return v
}

// handleProviderLiveness — GET /v1/providers/{id}/liveness
// Returns the pre-aggregated reliability summary for one provider.
func (s *Server) handleProviderLiveness(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdminKey(w, r) {
		return
	}
	providerID := r.PathValue("id")
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()

	row, err := s.store.GetReliabilityFeatures(ctx, providerID)
	if err != nil {
		s.logger.Error("liveness: get reliability features failed", "provider_id", providerID, "error", err)
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to load provider summary"))
		return
	}
	if row == nil {
		writeJSON(w, http.StatusNotFound, errorResponse("not_found", "no reliability data for provider"))
		return
	}
	writeJSON(w, http.StatusOK, row)
}

// handleProviderSessions — GET /v1/providers/{id}/sessions?window=7d&limit=50
func (s *Server) handleProviderSessions(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdminKey(w, r) {
		return
	}
	window, ok := parseLivenessWindow(r.URL.Query().Get("window"))
	if !ok {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "window must be one of: 24h, 7d, 30d"))
		return
	}
	limit := parseLivenessLimit(r.URL.Query().Get("limit"))
	providerID := r.PathValue("id")
	since := time.Now().Add(-window)

	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()

	rows, err := s.store.ListRecentSessions(ctx, providerID, since, limit)
	if err != nil {
		s.logger.Error("liveness: list sessions failed", "provider_id", providerID, "error", err)
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to load sessions"))
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"window":  r.URL.Query().Get("window"),
		"entries": rows,
	})
}

// handleProviderHeartbeats — GET /v1/providers/{id}/heartbeats?window=24h&limit=50
func (s *Server) handleProviderHeartbeats(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdminKey(w, r) {
		return
	}
	window, ok := parseLivenessWindow(r.URL.Query().Get("window"))
	if !ok {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request_error", "window must be one of: 24h, 7d, 30d"))
		return
	}
	limit := parseLivenessLimit(r.URL.Query().Get("limit"))
	providerID := r.PathValue("id")
	since := time.Now().Add(-window)

	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()

	rows, err := s.store.ListRecentHeartbeats(ctx, providerID, since, limit)
	if err != nil {
		s.logger.Error("liveness: list heartbeats failed", "provider_id", providerID, "error", err)
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to load heartbeats"))
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"window":  r.URL.Query().Get("window"),
		"entries": rows,
	})
}

// handleProviderReliability — GET /v1/providers/reliability?min_uptime=0.9&limit=50
// Shortlist of providers meeting a reliability bar.
func (s *Server) handleProviderReliability(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdminKey(w, r) {
		return
	}
	q := r.URL.Query()
	filter := store.ReliabilityFilter{
		MinUptimePct: parseUnitFloat(q.Get("min_uptime")),
		MinPStays4h:  parseUnitFloat(q.Get("min_stays_4h")),
		MinPStays8h:  parseUnitFloat(q.Get("min_stays_8h")),
		Limit:        parseLivenessLimit(q.Get("limit")),
	}
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()

	rows, err := s.store.ListReliabilityFeatures(ctx, filter)
	if err != nil {
		s.logger.Error("liveness: list reliability features failed", "error", err)
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to load reliable providers"))
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"min_uptime":   filter.MinUptimePct,
		"min_stays_4h": filter.MinPStays4h,
		"min_stays_8h": filter.MinPStays8h,
		"entries":      rows,
	})
}

// handleNetworkAvailability — GET /v1/network/availability
// Distributional fleet-wide availability stats (mean / p10 / p50 / p90).
func (s *Server) handleNetworkAvailability(w http.ResponseWriter, r *http.Request) {
	if !s.requireAdminKey(w, r) {
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()

	rows, err := s.store.ListReliabilityFeatures(ctx, store.ReliabilityFilter{})
	if err != nil {
		s.logger.Error("liveness: fleet availability failed", "error", err)
		writeJSON(w, http.StatusInternalServerError, errorResponse("internal_error", "failed to load fleet availability"))
		return
	}
	writeJSON(w, http.StatusOK, computeFleetAvailability(rows))
}

// computeFleetAvailability derives mean / percentile / count-above-95% stats
// from the per-provider reliability rows.
func computeFleetAvailability(rows []store.ReliabilityFeatures) map[string]any {
	if len(rows) == 0 {
		return map[string]any{
			"window_days":     14,
			"providers":       0,
			"mean_uptime_pct": 0.0,
			"p10_uptime_pct":  0.0,
			"p50_uptime_pct":  0.0,
			"p90_uptime_pct":  0.0,
			"highly_reliable": 0,
		}
	}
	uptimes := make([]float64, len(rows))
	var sum float64
	highly := 0
	for i, r := range rows {
		uptimes[i] = r.UptimePct
		sum += r.UptimePct
		if r.UptimePct >= 0.95 {
			highly++
		}
	}
	sort.Float64s(uptimes)
	pick := func(p float64) float64 {
		// math.Round (nearest-rank) so percentiles separate at small N —
		// truncation collapses p50 and p90 to the median when N=3.
		idx := int(math.Round(p * float64(len(uptimes)-1)))
		if idx < 0 {
			idx = 0
		}
		if idx >= len(uptimes) {
			idx = len(uptimes) - 1
		}
		return uptimes[idx]
	}
	return map[string]any{
		"window_days":     rows[0].WindowDays,
		"providers":       len(rows),
		"mean_uptime_pct": sum / float64(len(rows)),
		"p10_uptime_pct":  pick(0.10),
		"p50_uptime_pct":  pick(0.50),
		"p90_uptime_pct":  pick(0.90),
		"highly_reliable": highly,
	}
}
