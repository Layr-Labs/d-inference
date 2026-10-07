package reporting

import (
	"context"

	refresher "github.com/eigeninference/d-inference/coordinator/internal/api/reporting/refresher"
	"github.com/eigeninference/d-inference/coordinator/saferun"
)

// StartCacheRefreshers starts the goroutines that own the refreshed read-cache
// entries (stats:v1, stats:geography:v1 and network_totals:*). Independent
// loops keep slow geography queries off the core stats path. Stops when ctx
// is cancelled.
func (s *Owner) StartCacheRefreshers(ctx context.Context) {
	s.startAnalyticsSnapshots(ctx)
	saferun.Go(s.logger, "api.statsGeographyRefresher", func() {
		s.RunCacheRefreshLoop(ctx, refresher.StatsRefreshInterval, func() { s.RefreshStatsGeography() })
	})
	saferun.Go(s.logger, "api.statsRefresher", func() {
		s.RunStatsRefresher(ctx, refresher.StatsRefreshInterval)
	})
	if s.analyticsSnapshotPath == "" {
		saferun.Go(s.logger, "api.networkTotalsRefresher", func() {
			s.RunNetworkTotalsRefresher(ctx, refresher.CacheRefreshInterval)
		})
	}
}
