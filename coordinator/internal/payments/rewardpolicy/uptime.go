package rewardpolicy

import (
	"sort"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// uptimeByProviderKey unions overlapping session intervals per machine and
// returns the covered fraction of the period, capped at 1.0. Open sessions accrue
// only to min(end, last_seen + grace); blue-green deploys leave two open rows
// that union without double-counting (design §8). Sessions with no provider key
// (pre-backfill) are ignored — they cannot be credited.
func UptimeByProviderKey(sessions []store.ProviderSession, start, end time.Time, grace time.Duration) map[string]float64 {
	total := epochSeconds(start, end)

	type interval struct{ s, e time.Time }
	byKey := make(map[string][]interval)
	for _, ps := range sessions {
		if ps.ProviderKey == "" {
			continue
		}
		s := ps.ConnectedAt
		if s.Before(start) {
			s = start
		}
		var sessEnd time.Time
		if ps.DisconnectedAt != nil {
			// Closed session: clamp to min(disconnected_at, last_seen + grace) so a
			// stale eviction (disconnected well after last heartbeat) does not
			// overcount uptime.
			sessEnd = *ps.DisconnectedAt
			if graceEnd := ps.LastSeen.Add(grace); graceEnd.Before(sessEnd) {
				sessEnd = graceEnd
			}
		} else {
			// Open session: clamp to last_seen + grace.
			sessEnd = ps.LastSeen.Add(grace)
		}
		if sessEnd.After(end) {
			sessEnd = end
		}
		if !sessEnd.After(s) {
			continue
		}
		byKey[ps.ProviderKey] = append(byKey[ps.ProviderKey], interval{s, sessEnd})
	}

	out := make(map[string]float64, len(byKey))
	for key, ivs := range byKey {
		// Sort by start, then sweep-merge overlapping intervals (handles
		// blue-green double-open without double-counting).
		sort.Slice(ivs, func(i, j int) bool { return ivs[i].s.Before(ivs[j].s) })
		var covered float64
		curS, curE := ivs[0].s, ivs[0].e
		for _, iv := range ivs[1:] {
			if iv.s.After(curE) {
				covered += curE.Sub(curS).Seconds()
				curS, curE = iv.s, iv.e
				continue
			}
			if iv.e.After(curE) {
				curE = iv.e
			}
		}
		covered += curE.Sub(curS).Seconds()

		frac := 0.0
		if total > 0 {
			frac = covered / total
		}
		if frac > 1 {
			frac = 1 // no >100% uptime
		}
		out[key] = frac
	}
	return out
}
