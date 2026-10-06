package windows

import (
	"time"
)

// parseLeaderboardWindow returns the cutoff time for the requested
// window. Empty string and "all" return zero time (all-time).
func ParseLeaderboardWindow(s string) (time.Time, bool) {
	now := time.Now()
	switch s {
	case "", "all", "lifetime":
		return time.Time{}, true
	case "24h", "1d":
		return now.Add(-24 * time.Hour), true
	case "7d":
		return now.Add(-7 * 24 * time.Hour), true
	case "30d":
		return now.Add(-30 * 24 * time.Hour), true
	}
	return time.Time{}, false
}

func WindowParamOrDefault(s string) string {
	if s == "" {
		return "all"
	}
	return s
}
