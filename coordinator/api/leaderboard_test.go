package api

import (
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

type failingLeaderboardStore struct {
	store.Store
	fail bool
}

func (s *failingLeaderboardStore) Leaderboard(metric store.LeaderboardMetric, since time.Time, limit int) ([]store.LeaderboardRow, error) {
	if s.fail {
		return nil, errors.New("leaderboard unavailable")
	}
	return s.Store.Leaderboard(metric, since, limit)
}

func decodeLeaderboard(t *testing.T, rr *httptest.ResponseRecorder) map[string]any {
	t.Helper()
	var body map[string]any
	if err := json.Unmarshal(rr.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode body %q: %v", rr.Body.String(), err)
	}
	return body
}

// TestLeaderboardStoreErrorIs503NotEmptyBoard: a failed ranking query (in
// production the store's 10 s timeout) used to be served and cached for five
// minutes as 200 {"entries":[]}, indistinguishable from a network that earned
// nothing.
func TestLeaderboardStoreErrorIs503NotEmptyBoard(t *testing.T) {
	srv, mem := testServer(t)
	srv.logger = quietLogger()
	if err := mem.RecordProviderEarning(&store.ProviderEarning{
		AccountID: "acct-a", AmountMicroUSD: 100, PromptTokens: 10, CompletionTokens: 5, CreatedAt: time.Now(),
	}); err != nil {
		t.Fatal(err)
	}
	st := &failingLeaderboardStore{Store: mem, fail: true}
	srv.store = st
	const key = "leaderboard:earnings:24h:50"
	newReq := func() *http.Request {
		return httptest.NewRequest(http.MethodGet, "/v1/leaderboard?metric=earnings&window=24h", nil)
	}

	rr := httptest.NewRecorder()
	srv.handleLeaderboard(rr, newReq())
	if rr.Code != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want 503; body %s", rr.Code, rr.Body.String())
	}
	errObj, _ := decodeLeaderboard(t, rr)["error"].(map[string]any)
	if errObj["code"] != "service_unavailable" {
		t.Fatalf("error envelope = %v, want code service_unavailable", errObj)
	}
	if _, ok := srv.readCache.Get(key); ok {
		t.Fatal("failed leaderboard was cached")
	}

	st.fail = false
	rr = httptest.NewRecorder()
	srv.handleLeaderboard(rr, newReq())
	if rr.Code != http.StatusOK {
		t.Fatalf("status after recovery = %d, want 200; body %s", rr.Code, rr.Body.String())
	}
	entries, _ := decodeLeaderboard(t, rr)["entries"].([]any)
	if len(entries) != 1 {
		t.Fatalf("entries = %d, want 1", len(entries))
	}
	if _, ok := srv.readCache.Get(key); !ok {
		t.Fatal("successful leaderboard was not cached")
	}
}

// TestLeaderboardEmptyWindowIs200 pins the contract that a window with no
// earnings is a successful, cacheable empty board; only store errors are 503.
func TestLeaderboardEmptyWindowIs200(t *testing.T) {
	srv, _ := testServer(t)
	rr := httptest.NewRecorder()
	srv.handleLeaderboard(rr, httptest.NewRequest(http.MethodGet, "/v1/leaderboard?window=7d", nil))
	if rr.Code != http.StatusOK {
		t.Fatalf("status = %d, want 200; body %s", rr.Code, rr.Body.String())
	}
	entries, ok := decodeLeaderboard(t, rr)["entries"].([]any)
	if !ok || len(entries) != 0 {
		t.Fatalf("entries = %v, want empty array", entries)
	}
	if _, ok := srv.readCache.Get("leaderboard:earnings:7d:50"); !ok {
		t.Fatal("successful empty leaderboard was not cached")
	}
}
