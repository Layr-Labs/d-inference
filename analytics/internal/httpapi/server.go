package httpapi

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/eigeninference/analytics/internal/leaderboard"
)

type Service interface {
	Backend() string
	Ping(ctx context.Context) error
	Overview(ctx context.Context) (leaderboard.Overview, error)
	EarningsLeaderboard(ctx context.Context, query leaderboard.Query) (leaderboard.Leaderboard, error)
}

func NewHandler(logger *slog.Logger, service Service, allowOrigin string) http.Handler {
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

	return withCORS(allowOrigin, mux)
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
