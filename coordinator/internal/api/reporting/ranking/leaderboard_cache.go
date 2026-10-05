package ranking

import (
	"context"
	"fmt"
	"time"

	windows "github.com/eigeninference/d-inference/coordinator/internal/api/reporting/windows"
	"github.com/eigeninference/d-inference/coordinator/store"
)

const (
	CacheLimit          = 200
	leaderboardCacheTTL = 5 * time.Minute
	FailureBackoff      = 10 * time.Second
)

// Cache values are immutable. Limits and window aliases share the same top-200
// ranking; the handler truncates its view without changing these rows.
type leaderboardRanking struct {
	Rows      []store.LeaderboardRow
	UpdatedAt string
}

// A failed fill retains only a retry deadline, never an empty or partial ranking.
type leaderboardUnavailableError struct {
	retryAt time.Time
}

func (*leaderboardUnavailableError) Error() string {
	return "leaderboard is temporarily unavailable"
}

func LeaderboardRetryAfter(err error) int {
	retryAt := time.Now().Add(FailureBackoff)
	if unavailable, ok := err.(*leaderboardUnavailableError); ok {
		retryAt = unavailable.retryAt
	}
	remaining := time.Until(retryAt)
	seconds := int((remaining + time.Second - 1) / time.Second)
	if seconds < 1 {
		return 1
	}
	return seconds
}

func CacheKey(metric store.LeaderboardMetric, window string) string {
	return fmt.Sprintf("leaderboard:%s:%s:%d", metric, windows.NetworkTotalsWindow(window), CacheLimit)
}

func (s *Ranking) Cached(key string) (leaderboardRanking, error, bool) {
	value, ok := s.readCache.GetValue(key)
	if !ok {
		return leaderboardRanking{}, nil, false
	}
	switch cached := value.(type) {
	case leaderboardRanking:
		return cached, nil, true
	case *leaderboardUnavailableError:
		return leaderboardRanking{}, cached, true
	default:
		return leaderboardRanking{}, nil, false
	}
}

// At most one bounded query runs per metric/canonical window. Recheck inside
// the flight to cover delayed cache misses, and retain failure backoff so
// successive callers cannot immediately restart a failed expensive aggregate.
func (s *Ranking) CachedLeaderboard(ctx context.Context, metric store.LeaderboardMetric, window string) (leaderboardRanking, error) {
	if err := ctx.Err(); err != nil {
		return leaderboardRanking{}, err
	}
	window = windows.NetworkTotalsWindow(window)
	key := CacheKey(metric, window)
	if ranking, err, ok := s.Cached(key); ok {
		return ranking, err
	}
	result := s.leaderboardFlights.DoChan(key, func() (any, error) {
		if ranking, err, ok := s.Cached(key); ok {
			return ranking, err
		}
		since, ok := windows.ParseLeaderboardWindow(window)
		if !ok {
			return leaderboardRanking{}, fmt.Errorf("invalid leaderboard window: %s", window)
		}
		Rows, err := s.store.Leaderboard(metric, since, CacheLimit)
		if err != nil {
			s.logger.Warn("leaderboard query failed", "key", key, "error", err)
			s.ddIncr("cache.refresh_failed", []string{"key:" + key})
			unavailable := &leaderboardUnavailableError{retryAt: time.Now().Add(FailureBackoff)}
			if s.readCache != nil {
				s.readCache.SetValue(key, unavailable, FailureBackoff)
			}
			return leaderboardRanking{}, unavailable
		}
		ranking := leaderboardRanking{Rows: Rows, UpdatedAt: time.Now().UTC().Format(time.RFC3339)}
		if s.readCache != nil {
			s.readCache.SetValue(key, ranking, leaderboardCacheTTL)
		}
		return ranking, nil
	})
	select {
	case <-ctx.Done():
		return leaderboardRanking{}, ctx.Err()
	case completed := <-result:
		if completed.Err != nil {
			return leaderboardRanking{}, completed.Err
		}
		return completed.Val.(leaderboardRanking), nil
	}
}
