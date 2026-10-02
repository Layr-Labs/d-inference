package store

import (
	"reflect"
	"testing"
	"time"
)

// The index and return-type change must preserve all ranking components and
// the fixed-window boundary on the actual PostgreSQL query.
func TestLeaderboardBackendParity(t *testing.T) {
	mem := NewMemory(Config{})
	pg := testPostgresStore(t)
	seedLeaderboardStore(t, mem)
	seedLeaderboardStore(t, pg)
	for _, metric := range []LeaderboardMetric{LeaderboardEarnings, LeaderboardTokens, LeaderboardJobs} {
		for _, since := range []time.Time{time.Time{}, time.Now().Add(-24 * time.Hour), time.Now().Add(time.Hour)} {
			want := mustLeaderboard(t, mem, metric, since, 50)
			got := mustLeaderboard(t, pg, metric, since, 50)
			if !reflect.DeepEqual(got, want) {
				t.Fatalf("metric=%s since=%v: postgres=%+v memory=%+v", metric, since, got, want)
			}
		}
	}
}
