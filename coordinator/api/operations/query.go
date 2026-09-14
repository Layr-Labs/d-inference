package operations

import (
	"net/http"
	"strconv"
	"strings"
	"time"
)

// defaultBrowseLimit caps how many records the JSON browse handlers return when
// the caller does not pass an explicit ?limit=. Exports are uncapped by default.
const defaultBrowseLimit = 1000

// maxBrowseLimit bounds the caller-supplied ?limit= so a single browse response
// can't be asked to materialize an unreasonable number of rows. It matches the
// store-side read cap; the store never returns more than that regardless.
const maxBrowseLimit = 50000

// parseSince resolves the ?since= query parameter to an absolute lower-bound
// timestamp. It accepts either a Go duration relative to now (e.g. "24h",
// "168h") or an RFC3339 timestamp. When absent or unparseable it defaults to
// the last 24 hours.
func parseSince(r *http.Request) time.Time {
	raw := strings.TrimSpace(r.URL.Query().Get("since"))
	if raw != "" {
		if d, err := time.ParseDuration(raw); err == nil {
			if d < 0 {
				d = -d
			}
			return time.Now().Add(-d)
		}
		if t, err := time.Parse(time.RFC3339, raw); err == nil {
			return t
		}
	}
	return time.Now().Add(-24 * time.Hour)
}

// parseLimit reads ?limit= as a non-negative row cap, clamped to maxBrowseLimit.
// A missing or invalid value falls back to def; a value of 0 (or def == 0) means
// "no in-memory cap" (the store still hard-caps the underlying read).
func parseLimit(r *http.Request, def int) int {
	raw := strings.TrimSpace(r.URL.Query().Get("limit"))
	if raw == "" {
		return def
	}
	n, err := strconv.Atoi(raw)
	if err != nil || n < 0 {
		return def
	}
	if n > maxBrowseLimit {
		return maxBrowseLimit
	}
	return n
}

// capRecords truncates in to at most limit rows. limit <= 0 means no cap.
func capRecords[T any](in []T, limit int) []T {
	if limit > 0 && len(in) > limit {
		return in[:limit]
	}
	return in
}
