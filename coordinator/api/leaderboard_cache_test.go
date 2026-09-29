package api

import (
	"errors"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

type countedLeaderboardStore struct {
	store.Store
	calls   atomic.Int64
	entered chan struct{}
	release chan struct{}
	fail    atomic.Bool
}

func (s *countedLeaderboardStore) Leaderboard(metric store.LeaderboardMetric, since time.Time, limit int) ([]store.LeaderboardRow, error) {
	s.calls.Add(1)
	if limit != 200 {
		return nil, errors.New("expected a shared top-200 query")
	}
	if s.entered != nil {
		s.entered <- struct{}{}
		<-s.release
	}
	if s.fail.Load() {
		return nil, errors.New("query failed")
	}
	return s.Store.Leaderboard(metric, since, limit)
}
func TestLeaderboardAliasesAndLimitsShareOneQuery(t *testing.T) {
	srv, base := newMeTestServer(t)
	for _, account := range []string{"private-a", "private-b"} {
		if err := base.RecordProviderEarning(&store.ProviderEarning{AccountID: account, Model: "work", AmountMicroUSD: 1}); err != nil {
			t.Fatal(err)
		}
	}
	counted := &countedLeaderboardStore{Store: base, entered: make(chan struct{}, 20), release: make(chan struct{})}
	srv.store = counted
	var wg sync.WaitGroup
	responses := make(chan *httptest.ResponseRecorder, 20)
	for i := 0; i < 20; i++ {
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			url := "/v1/leaderboard?window=all&limit=1"
			if i%2 != 0 {
				url = "/v1/leaderboard?window=lifetime&limit=200"
			}
			w := httptest.NewRecorder()
			srv.handleLeaderboard(w, httptest.NewRequest("GET", url, nil))
			responses <- w
		}(i)
	}
	select {
	case <-counted.entered:
	case <-time.After(time.Second):
		t.Fatal("no query")
	}
	close(counted.release)
	wg.Wait()
	close(responses)
	if counted.calls.Load() != 1 {
		t.Fatalf("queries=%d", counted.calls.Load())
	}
	for w := range responses {
		if w.Code != 200 || strings.Contains(w.Body.String(), "private-") {
			t.Fatal(w.Code, w.Body.String())
		}
	}
}
func TestLeaderboardFailureIsNotCachedAsAnEmptyBoard(t *testing.T) {
	srv, base := newMeTestServer(t)
	counted := &countedLeaderboardStore{Store: base}
	counted.fail.Store(true)
	srv.store = counted
	w := httptest.NewRecorder()
	srv.handleLeaderboard(w, httptest.NewRequest("GET", "/v1/leaderboard", nil))
	if w.Code != 503 {
		t.Fatal(w.Code)
	}
	counted.fail.Store(false)
	w = httptest.NewRecorder()
	srv.handleLeaderboard(w, httptest.NewRequest("GET", "/v1/leaderboard", nil))
	if w.Code != 200 || !strings.Contains(w.Body.String(), `"entries":[]`) {
		t.Fatal(w.Code, w.Body.String())
	}
	if counted.calls.Load() != 2 {
		t.Fatal("failure populated cache")
	}
}
