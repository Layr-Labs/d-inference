package api

import (
	"context"
	"sync"
	"sync/atomic"
	"time"
)

// The stats refresher owns the readCache entries behind the public
// /v1/stats and /v1/network/totals endpoints.
//
// Why: /v1/stats runs two analytics statements that each sort every located
// usage row of the last 24 h. With a plain 60 s TTL, no coalescing, and an
// invalidation on every provider-location resolve, nearly every request
// started its own pipeline (≈1,200–1,950 runs/h instead of 60 in production,
// ≈75 % of the primary's CPU). The refresher makes the pipeline run on a
// timer, once per key, and lets handlers only read.
//
// Contract:
//   - handlers Get the entry; the request path never computes once warm;
//   - a miss (cold start, or a Server that never started the refresher)
//     recomputes through the same per-key flight, so N concurrent misses
//     run ONE pipeline and share its outcome;
//   - a failed or timed-out refresh never replaces a good body: the entry
//     is Set only on success, with a safety TTL long enough to ride out
//     several failed refreshes (stale-while-refreshing);
//   - nothing invalidates these keys.
const (
	// statsRefreshInterval is how often the refresher recomputes the owned
	// bodies; it is the steady-state staleness bound.
	statsRefreshInterval = time.Minute
	// statsCacheTTL is the safety bound: a refresh that fails or runs long
	// keeps serving the previous body for this long, after which the next
	// request falls back to the coalesced cold path.
	statsCacheTTL = 5 * time.Minute
	// refreshFailureHold is how long a key's flight answers with its last
	// error instead of running again. With nothing cached, every cold request
	// would otherwise start a fresh pipeline the moment the previous one
	// failed — on a database that is timing out, that stacks full scans
	// back-to-back. The hold is shorter than the tick so the timer always
	// retries; failed pipelines are capped at two per minute per key.
	refreshFailureHold = statsRefreshInterval / 2
)

// networkTotalsWindows are the /v1/network/totals windows kept warm — the
// canonical values windowParamOrDefault produces for the console and landing
// page; alias spellings (1d, lifetime) take the coalesced cold path.
var networkTotalsWindows = []string{"24h", "7d", "30d", "all"}

func networkTotalsCacheKey(window string) string { return "network_totals:" + window }

// refreshFlight coalesces concurrent refreshes of one cache key: one caller
// runs fn; a caller that arrives while it runs waits and shares its outcome
// instead of running a second pipeline. A mutex plus a generation counter is
// the whole contract needed (x/sync/singleflight is only an indirect
// dependency of this module).
type refreshFlight struct {
	mu       sync.Mutex
	gen      atomic.Uint64
	body     []byte
	err      error
	failedAt time.Time // when err was recorded; zero after a success
}

func (f *refreshFlight) do(fn func() ([]byte, error)) ([]byte, error) {
	seen := f.gen.Load()
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.gen.Load() != seen {
		// A refresh completed while this caller waited for the lock: share it.
		return f.body, f.err
	}
	if f.err != nil && time.Since(f.failedAt) < refreshFailureHold {
		// The last run failed moments ago: do not stack another pipeline on
		// a failing database. The timer (or a later request) retries once
		// the hold expires.
		return nil, f.err
	}
	f.body, f.err = fn()
	f.failedAt = time.Time{}
	if f.err != nil {
		f.failedAt = time.Now()
	}
	f.gen.Add(1)
	return f.body, f.err
}

// keyedFlights hands out one refreshFlight per cache key. Zero value ready.
type keyedFlights struct {
	mu sync.Mutex
	m  map[string]*refreshFlight
}

func (k *keyedFlights) get(key string) *refreshFlight {
	k.mu.Lock()
	defer k.mu.Unlock()
	if k.m == nil {
		k.m = make(map[string]*refreshFlight)
	}
	f := k.m[key]
	if f == nil {
		f = &refreshFlight{}
		k.m[key] = f
	}
	return f
}

// StartStatsRefresher recomputes the stats:v1 and network_totals:* cache
// entries immediately and then every statsRefreshInterval. Call as a
// goroutine; stops when ctx is cancelled.
func (s *Server) StartStatsRefresher(ctx context.Context) {
	s.runStatsRefresher(ctx, statsRefreshInterval)
}

// runStatsRefresher is StartStatsRefresher with an injectable interval (tests).
func (s *Server) runStatsRefresher(ctx context.Context, interval time.Duration) {
	s.refreshStatsCaches(ctx)
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			s.refreshStatsCaches(ctx)
		}
	}
}

// refreshStatsCaches runs one refresh of every owned key. Keys refresh in
// parallel so one window's slow statement cannot hold the others past the
// next tick; each key still runs at most one pipeline at a time.
func (s *Server) refreshStatsCaches(ctx context.Context) {
	var wg sync.WaitGroup
	wg.Add(1 + len(networkTotalsWindows))
	go func() {
		defer wg.Done()
		if _, err := s.refreshStats(ctx); err != nil {
			s.warnRefreshFailed(ctx, statsCacheKey, err)
		}
	}()
	for _, window := range networkTotalsWindows {
		go func() {
			defer wg.Done()
			if _, err := s.refreshNetworkTotals(window); err != nil {
				s.warnRefreshFailed(ctx, networkTotalsCacheKey(window), err)
			}
		}()
	}
	wg.Wait()
}

func (s *Server) warnRefreshFailed(ctx context.Context, key string, err error) {
	if ctx.Err() != nil || s.logger == nil {
		return
	}
	s.logger.Warn("stats refresh failed; serving previous value", "key", key, "error", err)
}

// refreshStats recomputes the /v1/stats body through its flight and stores
// it on success. Returns the body that callers on the cold path should serve.
func (s *Server) refreshStats(ctx context.Context) ([]byte, error) {
	return s.refreshFlights.get(statsCacheKey).do(func() ([]byte, error) {
		body, err := s.buildStatsBody(ctx)
		if err != nil {
			return nil, err
		}
		s.readCacheSet(statsCacheKey, body, statsCacheTTL)
		return body, nil
	})
}

// refreshNetworkTotals recomputes one /v1/network/totals window through its
// own flight (each window is an independent, slow statement) and stores it
// on success.
func (s *Server) refreshNetworkTotals(window string) ([]byte, error) {
	key := networkTotalsCacheKey(window)
	return s.refreshFlights.get(key).do(func() ([]byte, error) {
		body, err := s.buildNetworkTotalsBody(window)
		if err != nil {
			return nil, err
		}
		s.readCacheSet(key, body, statsCacheTTL)
		return body, nil
	})
}
