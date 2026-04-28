package httpapi

import (
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/darkbloom/analytics/internal/leaderboard"
	"github.com/darkbloom/analytics/internal/pseudonym"
)

func TestHealthz(t *testing.T) {
	handler := testHandler(t)

	req := httptest.NewRequest(http.MethodGet, "/healthz", nil)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusOK)
	}
	if got := rec.Header().Get("Access-Control-Allow-Origin"); got != "*" {
		t.Fatalf("allow origin = %q, want *", got)
	}
}

func TestEarningsLeaderboardEndpoint(t *testing.T) {
	handler := testHandler(t)

	req := httptest.NewRequest(http.MethodGet, "/v1/leaderboard/earnings?scope=account&window=7d&limit=3", nil)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", rec.Code, http.StatusOK)
	}

	var payload struct {
		Scope   string `json:"scope"`
		Window  string `json:"window"`
		Entries []struct {
			Rank           int    `json:"rank"`
			Alias          string `json:"alias"`
			EarnedMicroUSD int64  `json:"earned_micro_usd"`
		} `json:"entries"`
	}
	if err := json.NewDecoder(rec.Body).Decode(&payload); err != nil {
		t.Fatalf("decode response: %v", err)
	}

	if payload.Scope != "account" || payload.Window != "7d" {
		t.Fatalf("unexpected scope/window: %+v", payload)
	}
	if len(payload.Entries) != 3 {
		t.Fatalf("len(entries) = %d, want 3", len(payload.Entries))
	}
	if payload.Entries[0].Rank != 1 || payload.Entries[0].Alias == "" {
		t.Fatalf("unexpected first entry: %+v", payload.Entries[0])
	}
}

func TestBadLimit(t *testing.T) {
	handler := testHandler(t)

	req := httptest.NewRequest(http.MethodGet, "/v1/leaderboard/earnings?limit=abc", nil)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		body, _ := io.ReadAll(rec.Body)
		t.Fatalf("status = %d, want %d, body=%s", rec.Code, http.StatusBadRequest, string(body))
	}
}

func TestLimitTooLarge(t *testing.T) {
	handler := testHandler(t)

	req := httptest.NewRequest(http.MethodGet, "/v1/leaderboard/earnings?limit=101", nil)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		body, _ := io.ReadAll(rec.Body)
		t.Fatalf("status = %d, want %d, body=%s", rec.Code, http.StatusBadRequest, string(body))
	}
}

func TestOverviewEndpoint(t *testing.T) {
	handler := testHandler(t)

	req := httptest.NewRequest(http.MethodGet, "/v1/overview", nil)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		body, _ := io.ReadAll(rec.Body)
		t.Fatalf("status = %d, want %d, body=%s", rec.Code, http.StatusOK, string(body))
	}

	var payload struct {
		RegisteredNodes int64 `json:"registered_nodes"`
		ActiveNodes     int64 `json:"active_nodes"`
	}
	if err := json.NewDecoder(rec.Body).Decode(&payload); err != nil {
		t.Fatalf("decode response: %v", err)
	}
	if payload.RegisteredNodes != 5 || payload.ActiveNodes != 4 {
		t.Fatalf("unexpected overview payload: %+v", payload)
	}
}

func testHandler(t *testing.T) http.Handler {
	t.Helper()

	now := func() time.Time {
		return time.Date(2026, time.April, 15, 12, 0, 0, 0, time.UTC)
	}
	store := leaderboard.NewMemoryStoreWithClock(2*time.Minute, now)
	aliaser, err := pseudonym.NewGenerator("secret")
	if err != nil {
		t.Fatalf("NewGenerator: %v", err)
	}

	service := leaderboard.NewService(store, aliaser, now)
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	return NewHandler(logger, service, "*")
}
