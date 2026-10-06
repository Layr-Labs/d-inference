package store_test

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestLeaderboardReturnsErrorWhenUnavailable(t *testing.T) {
	s := testPostgresStore(t)
	s.Close()
	if _, err := s.Leaderboard(store.LeaderboardEarnings, time.Now().Add(-24*time.Hour), 50); err == nil {
		t.Fatal("Leaderboard on a closed pool returned no error")
	}
}
