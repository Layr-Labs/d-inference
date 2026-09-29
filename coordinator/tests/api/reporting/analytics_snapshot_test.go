package reporting_test

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/analyticssnapshot"
	"github.com/eigeninference/d-inference/coordinator/api/readcache"
	"github.com/eigeninference/d-inference/coordinator/api/reporting"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

type noAnalyticsScan struct {
	store.Store
	t               *testing.T
	seriesCalls     *atomic.Int64
	statsSeriesDone chan struct{}
}

func (s noAnalyticsScan) Leaderboard(store.LeaderboardMetric, time.Time, int) ([]store.LeaderboardRow, error) {
	s.t.Fatal("scanned PostgreSQL leaderboard")
	return nil, nil
}
func (s noAnalyticsScan) UsageTimeSeries(start, end time.Time, step time.Duration) ([]store.UsageBucket, error) {
	s.seriesCalls.Add(1)
	rows, err := s.Store.UsageTimeSeries(start, end, step)
	s.statsSeriesDone <- struct{}{}
	return rows, err
}
func (s noAnalyticsScan) NetworkTotals(time.Time) (store.NetworkTotalsRow, error) {
	s.t.Fatal("scanned PostgreSQL totals")
	return store.NetworkTotalsRow{}, nil
}

func TestArchiveAnalyticsNeverScansSourceAndKeepsPseudonyms(t *testing.T) {
	now := time.Now().UTC()
	path := filepath.Join(t.TempDir(), "snapshot.json")
	snapshot := analyticssnapshot.Snapshot{SchemaVersion: 1, Generation: "generation1", ReconciliationID: "verified", SourceComplete: true, SourceCompleteThrough: now.Add(-time.Minute), AsOf: now.Add(-time.Minute), GeneratedAt: now, Windows: map[string]analyticssnapshot.Window{}}
	row := store.LeaderboardRow{AccountID: "private-account-identifier", EarningsMicroUSD: 123, WorkEarningsMicroUSD: 100, RewardEarningsMicroUSD: 23, Tokens: 12, Jobs: 2}
	for _, window := range analyticssnapshot.Windows {
		snapshot.Windows[window] = analyticssnapshot.Window{Leaderboards: map[string][]store.LeaderboardRow{"earnings": {row}, "tokens": {row}, "jobs": {row}}, Totals: store.NetworkTotalsRow{EarningsMicroUSD: 123, WorkEarningsMicroUSD: 100, RewardEarningsMicroUSD: 23, Tokens: 12, Jobs: 2, ActiveAccounts: 1}}
	}
	snapshot.Series = map[string]analyticssnapshot.Series{}
	for name, spec := range analyticssnapshot.SeriesSpecs {
		end := snapshot.AsOf.UTC().Truncate(spec.Bucket)
		snapshot.Series[name] = analyticssnapshot.Series{Start: end.Add(-spec.Lookback), End: end, BucketSeconds: int64(spec.Bucket / time.Second), Buckets: []store.UsageBucket{}}
	}
	b, e := json.Marshal(snapshot)
	if e != nil {
		t.Fatal(e)
	}
	if e = os.WriteFile(path, b, 0600); e != nil {
		t.Fatal(e)
	}
	cache := readcache.New()
	statePath := filepath.Join(t.TempDir(), "accepted.json")
	if err := os.WriteFile(statePath, []byte(`{"version":1,"checksums":{}}`), 0600); err != nil {
		t.Fatal(err)
	}
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	var seriesCalls atomic.Int64
	statsSeriesDone := make(chan struct{}, 10)
	s := reporting.New(reporting.Dependencies{AnalyticsSnapshotPath: path, AnalyticsSnapshotStatePath: statePath, Store: noAnalyticsScan{Store: memory.NewMemory(store.Config{}), t: t, seriesCalls: &seriesCalls, statsSeriesDone: statsSeriesDone}, Cache: cache, Registry: registry.New(logger), Logger: logger})
	// No valid snapshot must fail closed even if an old ordinary cache was populated.
	cache.Set("leaderboard:earnings:all:50", []byte(`{"entries":[]}`), time.Hour)
	missing := httptest.NewRecorder()
	s.HandleLeaderboard(missing, httptest.NewRequest("GET", "/v1/leaderboard?window=all", nil))
	if missing.Code != 503 {
		t.Fatal(missing.Code)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	s.StartCacheRefreshers(ctx)
	// Core stats retain their independent database-backed series refresh.
	select {
	case <-statsSeriesDone:
	case <-time.After(5 * time.Second):
		t.Fatal("core stats did not refresh")
	}
	for deadline := time.Now().Add(5 * time.Second); ; {
		w := httptest.NewRecorder()
		s.HandleLeaderboard(w, httptest.NewRequest("GET", "/v1/leaderboard?window=all", nil))
		if w.Code == 200 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("snapshot did not become available", w.Body.String())
		}
		time.Sleep(time.Millisecond)
	}
	for _, test := range []struct {
		path    string
		handler func(*httptest.ResponseRecorder)
	}{
		{"leaderboard", func(w *httptest.ResponseRecorder) {
			s.HandleLeaderboard(w, httptest.NewRequest("GET", "/v1/leaderboard?window=lifetime", nil))
		}},
		{"series", func(w *httptest.ResponseRecorder) {
			s.HandleNetworkSeries(w, httptest.NewRequest("GET", "/v1/network/series?window=30d", nil))
		}},
		{"totals", func(w *httptest.ResponseRecorder) {
			s.HandleNetworkTotals(w, httptest.NewRequest("GET", "/v1/network/totals?window=1d", nil))
		}},
	} {
		t.Run(test.path, func(t *testing.T) {
			w := httptest.NewRecorder()
			test.handler(w)
			if w.Code != 200 {
				t.Fatal(w.Code, w.Body.String())
			}
			if strings.Contains(w.Body.String(), row.AccountID) {
				t.Fatal("leaked account ID")
			}
			if !strings.Contains(w.Body.String(), snapshot.AsOf.Format(time.RFC3339)) {
				t.Fatal("incorrect as-of time")
			}
		})
	}
	if got := seriesCalls.Load(); got != 1 {
		t.Fatalf("snapshot handlers queried series: got %d calls, want only the core stats refresh", got)
	}
}
