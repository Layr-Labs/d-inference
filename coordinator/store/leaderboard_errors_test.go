package store

import (
	"testing"
	"time"
)

func TestLeaderboardReturnsErrorWhenUnavailable(t *testing.T) {
	s := testPostgresStore(t)
	s.Close()
	if _, err := s.Leaderboard(LeaderboardEarnings, time.Now().Add(-24*time.Hour), 50); err == nil {
		t.Fatal("Leaderboard on a closed pool returned no error")
	}
}
