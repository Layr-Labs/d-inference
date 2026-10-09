package totalsview

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	refresher "github.com/eigeninference/d-inference/coordinator/internal/api/reporting/refresher"
	windows "github.com/eigeninference/d-inference/coordinator/internal/api/reporting/windows"
)

// networkTotalsWindows are the canonical windows the refresher keeps warm;
// the handler maps aliases (1d, lifetime, "") onto them.
var Windows = []string{"24h", "7d", "30d", "all"}

func NetworkTotalsCacheKey(window string) string { return "network_totals:" + window }

// networkTotalsEntry returns the refresher state for one window.
func (s *Totals) networkTotalsEntry(window string) *refresher.Entry {
	r := &s.networkTotalsRefresh
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.entries == nil {
		r.entries = make(map[string]*refresher.Entry, len(Windows))
	}
	entry := r.entries[window]
	if entry == nil {
		entry = &refresher.Entry{TTL: 15 * time.Minute}
		r.entries[window] = entry
	}
	return entry
}

// refreshNetworkTotals computes one window's totals (coalesced) and caches
// them. A store error leaves the previously cached value in place — the
// statement scans provider_earnings three times and used to come back as an
// all-zero row on its 10 s timeout, which the handler then cached and served.
func (s *Totals) RefreshNetworkTotals(window string) ([]byte, bool) {
	return s.RefreshCachedEntry(s.networkTotalsEntry(window), NetworkTotalsCacheKey(window), func() ([]byte, error) {
		return s.ComputeNetworkTotals(window)
	})
}

func (s *Totals) ComputeNetworkTotals(window string) ([]byte, error) {
	// Cold fills for distinct windows share the background loop's one-query
	// concurrency bound; each transaction raises work_mem for several scans.
	s.networkTotalsRefresh.queryMu.Lock()
	defer s.networkTotalsRefresh.queryMu.Unlock()
	since, ok := windows.ParseLeaderboardWindow(window)
	if !ok {
		return nil, fmt.Errorf("invalid network totals window: %s", window)
	}
	totals, err := s.store.NetworkTotals(since)
	if err != nil {
		return nil, err
	}
	return json.Marshal(map[string]any{
		"window":                    window,
		"earnings_micro_usd":        totals.EarningsMicroUSD,
		"work_earnings_micro_usd":   totals.WorkEarningsMicroUSD,
		"reward_earnings_micro_usd": totals.RewardEarningsMicroUSD,
		"tokens":                    totals.Tokens,
		"jobs":                      totals.Jobs,
		"active_accounts":           totals.ActiveAccounts,
		"updated_at":                time.Now().UTC().Format(time.RFC3339),
	})
}

// runNetworkTotalsRefresher owns every network_totals:<window> entry with an
// injectable interval. The windows are computed one after another; all four
// were already requested continuously in production, so the cadence adds no
// load — it only removes the per-request misses and the cached zero rows.
func (s *Totals) RunNetworkTotalsRefresher(ctx context.Context, interval time.Duration) {
	s.RunCacheRefreshLoop(ctx, interval, func() {
		for _, window := range Windows {
			if ctx.Err() != nil {
				return
			}
			s.RefreshNetworkTotals(window)
		}
	})
}
