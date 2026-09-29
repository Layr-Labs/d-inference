package api

import (
	"context"
	"errors"
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/saferun"
)

const (
	cacheRefreshInterval = time.Minute
	// Stats has a shorter freshness window than the network earnings totals.
	statsRefreshInterval = 30 * time.Second
	// Failed refreshes retain the previous success only until this safety TTL.
	refreshedCacheTTL = 5 * time.Minute
)

// coldFillWait bounds how long a request that misses the cache waits for a
// compute already in flight. Healthy computes finish well inside it; one that
// is heading for the store timeout must not hold requests for its full 10 s.
var coldFillWait = 2 * time.Second

// errComputeBusy is returned by a compute that declined to run because the
// background refresher already owns the query. It is not a refresh failure:
// nothing is logged or counted, the caller simply serves what is cached.
var errComputeBusy = errors.New("cache: refresh already in flight")

// cacheRefresher coalesces computations of one read-cache entry. Only complete
// successful results are cached; query errors never become partial JSON data.
type cacheRefresher struct {
	mu       sync.Mutex
	inflight chan struct{}
}

// getCachedEntry fills a cold cache. It rechecks the cache under the flight
// lock so a request delayed after its initial miss cannot start a second
// expensive query after another request has already populated the entry.
func (s *Server) getCachedEntry(entry *cacheRefresher, key string, compute func() ([]byte, error)) ([]byte, bool) {
	return s.computeCachedEntry(entry, key, false, compute)
}

// refreshCachedEntry forces a periodic refresh, sharing any existing flight.
func (s *Server) refreshCachedEntry(entry *cacheRefresher, key string, compute func() ([]byte, error)) ([]byte, bool) {
	return s.computeCachedEntry(entry, key, true, compute)
}

func (s *Server) computeCachedEntry(entry *cacheRefresher, key string, refresh bool, compute func() ([]byte, error)) ([]byte, bool) {
	entry.mu.Lock()
	if !refresh {
		if body, ok := s.readCache.Get(key); ok {
			entry.mu.Unlock()
			return body, true
		}
	}
	if wait := entry.inflight; wait != nil {
		entry.mu.Unlock()
		if refresh {
			<-wait
		} else {
			// A request joins a flight only briefly; past coldFillWait it answers
			// from whatever is cached (or 503s) rather than queueing behind a
			// compute that is timing out.
			select {
			case <-wait:
			case <-time.After(coldFillWait):
			}
		}
		return s.readCache.Get(key)
	}
	done := make(chan struct{})
	entry.inflight = done
	entry.mu.Unlock()
	defer func() {
		entry.mu.Lock()
		entry.inflight = nil
		close(done)
		entry.mu.Unlock()
	}()

	body, err := compute()
	if errors.Is(err, errComputeBusy) {
		return s.readCache.Get(key)
	}
	if err != nil {
		s.logger.Warn("cache refresh failed; keeping previous value", "key", key, "error", err)
		s.ddIncr("cache.refresh_failed", []string{"key:" + key})
		return s.readCache.Get(key)
	}
	s.readCache.Set(key, body, refreshedCacheTTL)
	return body, true
}

// runCacheRefreshLoop computes once at start and then every interval until
// ctx is cancelled.
func (s *Server) runCacheRefreshLoop(ctx context.Context, interval time.Duration, refresh func()) {
	if s.readCache == nil || ctx.Err() != nil {
		return
	}
	refresh()
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			refresh()
		}
	}
}

// StartCacheRefreshers starts the goroutines that own the refreshed read-cache
// entries (stats:v1, stats:geography:v1 and network_totals:*). Independent
// loops keep slow geography queries off the core stats path. Stops when ctx
// is cancelled.
func (s *Server) StartCacheRefreshers(ctx context.Context) {
	saferun.Go(s.logger, "api.statsGeographyRefresher", func() {
		s.runCacheRefreshLoop(ctx, statsRefreshInterval, func() { s.refreshStatsGeography() })
	})
	saferun.Go(s.logger, "api.statsRefresher", func() {
		s.runStatsRefresher(ctx, statsRefreshInterval)
	})
	saferun.Go(s.logger, "api.networkTotalsRefresher", func() {
		s.runNetworkTotalsRefresher(ctx, cacheRefreshInterval)
	})
}
