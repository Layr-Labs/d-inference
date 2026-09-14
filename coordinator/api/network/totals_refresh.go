package network

import (
	"context"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/readcache"
)

// Canonical earnings windows; aliases are normalized before lookup.
var networkTotalsWindows = []string{"24h", "7d", "30d", "all"}

func networkTotalsWindow(param string) string {
	switch param {
	case "1d":
		return "24h"
	case "", "lifetime":
		return "all"
	}
	return param
}

func networkTotalsCacheKey(window string) string { return "network_totals:" + window }

// networkTotalsEntry returns the refresher state for one window.
func (s *Controller) networkTotalsEntry(window string) *readcache.Refresher {
	r := &s.networkTotalsRefresh
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.entries == nil {
		r.entries = make(map[string]*readcache.Refresher, len(networkTotalsWindows))
	}
	entry := r.entries[window]
	if entry == nil {
		entry = &readcache.Refresher{}
		r.entries[window] = entry
	}
	return entry
}

// refreshNetworkTotals computes one window's totals (coalesced) and caches
// them. A store error leaves the previously cached value in place — the
// statement scans provider_earnings three times and used to come back as an
// all-zero row on its 10 s timeout, which the handler then cached and served.
func (s *Controller) refreshNetworkTotals(window string) ([]byte, bool) {
	return s.refreshCachedEntry(s.networkTotalsEntry(window), networkTotalsCacheKey(window), func() ([]byte, error) {
		return s.computeNetworkTotals(window)
	})
}

// runNetworkTotalsRefresher owns every network_totals:<window> entry with an
// injectable interval. The windows are computed one after another; all four
// were already requested continuously in production, so the cadence adds no
// load — it only removes the per-request misses and the cached zero rows.
func (s *Controller) runNetworkTotalsRefresher(ctx context.Context, interval time.Duration) {
	s.runCacheRefreshLoop(ctx, interval, func() {
		for _, window := range networkTotalsWindows {
			if ctx.Err() != nil {
				return
			}
			s.refreshNetworkTotals(window)
		}
	})
}
