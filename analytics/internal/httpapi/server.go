package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/eigeninference/analytics/internal/leaderboard"
	"github.com/eigeninference/analytics/internal/liveness"
)

type Service interface {
	Backend() string
	Ping(ctx context.Context) error
	Overview(ctx context.Context) (leaderboard.Overview, error)
	EarningsLeaderboard(ctx context.Context, query leaderboard.Query) (leaderboard.Leaderboard, error)
}

// LivenessService is the subset of the liveness package's Service that the
// HTTP layer needs. Separate interface so the httpapi tests can stub it.
type LivenessService interface {
	ProviderSummary(ctx context.Context, providerID string) (*liveness.Summary, error)
	ProviderSessions(ctx context.Context, providerID string, window liveness.Window, limit int) ([]liveness.SessionEntry, error)
	ProviderHeartbeats(ctx context.Context, providerID string, window liveness.Window, limit int) ([]liveness.HeartbeatEntry, error)
	ReliableProviders(ctx context.Context, filter liveness.ReliabilityFilterInput) ([]liveness.ReliabilityEntry, error)
	FleetAvailability(ctx context.Context) (liveness.FleetAvailability, error)
}

// NewHandler returns the analytics HTTP handler. livenessSvc may be nil
// when liveness endpoints aren't wired (e.g., memory-mode dev runs).
func NewHandler(logger *slog.Logger, service Service, livenessSvc LivenessService, allowOrigin string) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), 2*time.Second)
		defer cancel()

		status := "ok"
		code := http.StatusOK
		if err := service.Ping(ctx); err != nil {
			status = "degraded"
			code = http.StatusServiceUnavailable
			logger.Warn("analytics health check failed", "error", err)
		}

		writeJSON(w, code, map[string]any{
			"status":     status,
			"backend":    service.Backend(),
			"checked_at": time.Now().UTC(),
		})
	})

	mux.HandleFunc("GET /v1/overview", func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
		defer cancel()

		overview, err := service.Overview(ctx)
		if err != nil {
			logger.Error("overview request failed", "error", err)
			writeError(w, http.StatusInternalServerError, "internal_error", "failed to load analytics overview")
			return
		}

		writeJSON(w, http.StatusOK, overview)
	})

	mux.HandleFunc("GET /v1/leaderboard/earnings", func(w http.ResponseWriter, r *http.Request) {
		scope, err := leaderboard.ParseScope(r.URL.Query().Get("scope"))
		if err != nil {
			writeError(w, http.StatusBadRequest, "bad_request", err.Error())
			return
		}

		window, err := leaderboard.ParseWindow(r.URL.Query().Get("window"))
		if err != nil {
			writeError(w, http.StatusBadRequest, "bad_request", err.Error())
			return
		}

		limit := 0
		if raw := strings.TrimSpace(r.URL.Query().Get("limit")); raw != "" {
			parsed, err := strconv.Atoi(raw)
			if err != nil {
				writeError(w, http.StatusBadRequest, "bad_request", "limit must be an integer")
				return
			}
			if parsed < 1 || parsed > leaderboard.MaxLimit {
				writeError(w, http.StatusBadRequest, "bad_request", "limit must be between 1 and 100")
				return
			}
			limit = parsed
		}

		ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
		defer cancel()

		board, err := service.EarningsLeaderboard(ctx, leaderboard.Query{
			Scope:  scope,
			Window: window,
			Limit:  limit,
		})
		if err != nil {
			logger.Error("earnings leaderboard request failed", "error", err)
			writeError(w, http.StatusInternalServerError, "internal_error", "failed to load leaderboard")
			return
		}

		writeJSON(w, http.StatusOK, board)
	})

	if livenessSvc != nil {
		registerLivenessRoutes(mux, logger, livenessSvc)
	}

	return withCORS(allowOrigin, mux)
}

// registerLivenessRoutes wires the provider-liveness endpoints. Split out
// from NewHandler so it's easy to see what's gated behind livenessSvc != nil.
func registerLivenessRoutes(mux *http.ServeMux, logger *slog.Logger, svc LivenessService) {
	mux.HandleFunc("GET /v1/providers/{id}/liveness", func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
		defer cancel()

		providerID := r.PathValue("id")
		summary, err := svc.ProviderSummary(ctx, providerID)
		if err != nil {
			logger.Error("provider summary failed", "provider_id", providerID, "error", err)
			writeError(w, http.StatusInternalServerError, "internal_error", "failed to load provider summary")
			return
		}
		if summary == nil {
			writeError(w, http.StatusNotFound, "not_found", "no reliability data for provider")
			return
		}
		writeJSON(w, http.StatusOK, summary)
	})

	mux.HandleFunc("GET /v1/providers/{id}/sessions", func(w http.ResponseWriter, r *http.Request) {
		window, limit, err := parseLivenessQuery(r)
		if err != nil {
			writeError(w, http.StatusBadRequest, "bad_request", err.Error())
			return
		}
		ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
		defer cancel()

		entries, err := svc.ProviderSessions(ctx, r.PathValue("id"), window, limit)
		if err != nil {
			logger.Error("provider sessions failed", "error", err)
			writeError(w, http.StatusInternalServerError, "internal_error", "failed to load sessions")
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{
			"window":  string(window),
			"entries": entries,
		})
	})

	mux.HandleFunc("GET /v1/providers/{id}/heartbeats", func(w http.ResponseWriter, r *http.Request) {
		window, limit, err := parseLivenessQuery(r)
		if err != nil {
			writeError(w, http.StatusBadRequest, "bad_request", err.Error())
			return
		}
		ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
		defer cancel()

		entries, err := svc.ProviderHeartbeats(ctx, r.PathValue("id"), window, limit)
		if err != nil {
			logger.Error("provider heartbeats failed", "error", err)
			writeError(w, http.StatusInternalServerError, "internal_error", "failed to load heartbeats")
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{
			"window":  string(window),
			"entries": entries,
		})
	})

	mux.HandleFunc("GET /v1/providers/reliability", func(w http.ResponseWriter, r *http.Request) {
		filter := liveness.ReliabilityFilterInput{
			MinUptimePct: parseFloat(r.URL.Query().Get("min_uptime"), 0),
			MinPStays4h:  parseFloat(r.URL.Query().Get("min_stays_4h"), 0),
			MinPStays8h:  parseFloat(r.URL.Query().Get("min_stays_8h"), 0),
			Limit:        parseIntDefault(r.URL.Query().Get("limit"), liveness.DefaultLimit),
		}
		ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
		defer cancel()

		entries, err := svc.ReliableProviders(ctx, filter)
		if err != nil {
			logger.Error("reliable providers failed", "error", err)
			writeError(w, http.StatusInternalServerError, "internal_error", "failed to load reliable providers")
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{
			"min_uptime":   filter.MinUptimePct,
			"min_stays_4h": filter.MinPStays4h,
			"min_stays_8h": filter.MinPStays8h,
			"entries":      entries,
		})
	})

	mux.HandleFunc("GET /v1/network/availability", func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
		defer cancel()

		summary, err := svc.FleetAvailability(ctx)
		if err != nil {
			logger.Error("network availability failed", "error", err)
			writeError(w, http.StatusInternalServerError, "internal_error", "failed to load fleet availability")
			return
		}
		writeJSON(w, http.StatusOK, summary)
	})
}

// parseLivenessQuery extracts the shared `window` + `limit` query params
// used by the per-provider endpoints.
func parseLivenessQuery(r *http.Request) (liveness.Window, int, error) {
	window, err := liveness.ParseWindow(r.URL.Query().Get("window"))
	if err != nil {
		var pe *liveness.ParseError
		if errors.As(err, &pe) {
			return "", 0, err
		}
		return "", 0, err
	}
	limit := parseIntDefault(r.URL.Query().Get("limit"), liveness.DefaultLimit)
	return window, limit, nil
}

func parseFloat(raw string, fallback float64) float64 {
	if raw == "" {
		return fallback
	}
	v, err := strconv.ParseFloat(raw, 64)
	if err != nil {
		return fallback
	}
	if v < 0 {
		return 0
	}
	if v > 1 {
		return 1
	}
	return v
}

func parseIntDefault(raw string, fallback int) int {
	if strings.TrimSpace(raw) == "" {
		return fallback
	}
	v, err := strconv.Atoi(raw)
	if err != nil || v <= 0 {
		return fallback
	}
	return v
}

func withCORS(allowOrigin string, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if allowOrigin != "" {
			w.Header().Set("Access-Control-Allow-Origin", allowOrigin)
			w.Header().Set("Access-Control-Allow-Methods", "GET, OPTIONS")
			w.Header().Set("Access-Control-Allow-Headers", "Content-Type")
		}
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		next.ServeHTTP(w, r)
	})
}

func writeError(w http.ResponseWriter, status int, code, message string) {
	writeJSON(w, status, map[string]any{
		"error": map[string]string{
			"code":    code,
			"message": message,
		},
	})
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}
