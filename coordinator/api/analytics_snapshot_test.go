package api

import (
	"encoding/json"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/analyticssnapshot"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type noAnalyticsScan struct {
	store.Store
	t *testing.T
}

func (s noAnalyticsScan) Leaderboard(store.LeaderboardMetric, time.Time, int) ([]store.LeaderboardRow, error) {
	s.t.Fatal("scanned PostgreSQL leaderboard")
	return nil, nil
}
func (s noAnalyticsScan) UsageTimeSeries(time.Time, time.Time, time.Duration) ([]store.UsageBucket, error) {
	s.t.Fatal("scanned PostgreSQL series")
	return nil, nil
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
	s := &Server{analyticsSnapshotPath: path, store: noAnalyticsScan{t: t}}
	// No valid snapshot must fail closed even if an old ordinary cache was populated.
	s.readCache = newTTLCache()
	s.readCache.Set("leaderboard:earnings:all:50", []byte(`{"entries":[]}`), time.Hour)
	missing := httptest.NewRecorder()
	s.handleLeaderboard(missing, httptest.NewRequest("GET", "/v1/leaderboard?window=all", nil))
	if missing.Code != 503 {
		t.Fatal(missing.Code)
	}
	if e = s.analyticsSnapshot.Load(path, now); e != nil {
		t.Fatal(e)
	}
	for _, test := range []struct {
		path    string
		handler func(*httptest.ResponseRecorder)
	}{
		{"leaderboard", func(w *httptest.ResponseRecorder) {
			s.handleLeaderboard(w, httptest.NewRequest("GET", "/v1/leaderboard?window=lifetime", nil))
		}},
		{"series", func(w *httptest.ResponseRecorder) {
			s.handleNetworkSeries(w, httptest.NewRequest("GET", "/v1/network/series?window=30d", nil))
		}},
		{"totals", func(w *httptest.ResponseRecorder) {
			s.handleNetworkTotals(w, httptest.NewRequest("GET", "/v1/network/totals?window=1d", nil))
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
}
