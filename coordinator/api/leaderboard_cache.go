package api

import (
	"encoding/json"
	"fmt"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

type cachedLeaderboard struct {
	Rows      []store.LeaderboardRow `json:"rows"`
	UpdatedAt time.Time              `json:"updated_at"`
}

// Canonical windows and one top-200 result share a single flight across limits
// and aliases. Private account IDs stay inside this cache, never the HTTP body.
func (s *Server) cachedLeaderboard(metric store.LeaderboardMetric, window string, since time.Time) (cachedLeaderboard, bool) {
	key := fmt.Sprintf("leaderboard_data:%s:%s", metric, networkTotalsWindow(window))
	s.leaderboardRefresh.mu.Lock()
	if s.leaderboardRefresh.entries == nil {
		s.leaderboardRefresh.entries = map[string]*cacheRefresher{}
	}
	entry := s.leaderboardRefresh.entries[key]
	if entry == nil {
		entry = &cacheRefresher{}
		s.leaderboardRefresh.entries[key] = entry
	}
	s.leaderboardRefresh.mu.Unlock()
	raw, ok := s.getCachedEntry(entry, key, func() ([]byte, error) {
		rows, err := s.store.Leaderboard(metric, since, 200)
		if err != nil {
			return nil, err
		}
		if len(rows) > 200 {
			return nil, fmt.Errorf("leaderboard result exceeds requested limit")
		}
		if rows == nil {
			rows = []store.LeaderboardRow{}
		}
		return json.Marshal(cachedLeaderboard{Rows: rows, UpdatedAt: time.Now().UTC()})
	})
	if !ok {
		return cachedLeaderboard{}, false
	}
	var result cachedLeaderboard
	if err := json.Unmarshal(raw, &result); err != nil {
		return cachedLeaderboard{}, false
	}
	return result, true
}
