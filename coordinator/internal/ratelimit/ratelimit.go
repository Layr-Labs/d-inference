// Package ratelimit provides per-account token-bucket rate limiting for the
// coordinator's consumer-facing endpoints.
//
// One token bucket per account, lazily created on first request, pruned
// after a configurable idle window so memory stays bounded even with
// large account churn.
//
// Use Limiter from one goroutine per request — Allow is concurrency-safe.
package ratelimit

import (
	"context"
	"log/slog"
	"sync"
	"time"

	"golang.org/x/time/rate"
)

// Defaults tuned conservatively. Operators can override via the Config
// struct passed to New (typically populated from env vars in main).
const (
	DefaultRPS        = 1.0
	DefaultBurst      = 10
	DefaultIdleEvict  = 30 * time.Minute
	DefaultPruneEvery = 5 * time.Minute
	DefaultRetryAfter = time.Second
	maxRetryAfter     = 60 * time.Second
)

// Config controls the limiter's behavior. Zero values fall back to the
// Default* constants so callers can pass an empty Config in tests.
type Config struct {
	RPS        float64       // sustained rate
	Burst      int           // bucket capacity
	IdleEvict  time.Duration // drop accounts not seen for this long
	PruneEvery time.Duration // how often to scan for idle accounts
}

// Limiter holds a token bucket per account.
type Limiter struct {
	cfg Config

	mu      sync.Mutex
	buckets map[string]*entry
}

type entry struct {
	limiter  *rate.Limiter
	lastSeen time.Time
}

// New constructs a Limiter with the given config. Zero-value fields fall
// back to defaults.
func New(cfg Config) *Limiter {
	if cfg.RPS <= 0 {
		cfg.RPS = DefaultRPS
	}
	if cfg.Burst <= 0 {
		cfg.Burst = DefaultBurst
	}
	if cfg.IdleEvict <= 0 {
		cfg.IdleEvict = DefaultIdleEvict
	}
	if cfg.PruneEvery <= 0 {
		cfg.PruneEvery = DefaultPruneEvery
	}
	return &Limiter{
		cfg:     cfg,
		buckets: make(map[string]*entry),
	}
}

// Allow reports whether the account may make one request right now. If
// false, retryAfter is the minimum wait until the next token is available
// (clamped to maxRetryAfter to give a sane Retry-After header value).
//
// Empty accountID is allowed unconditionally — caller should validate
// authentication before calling Allow.
//
// Implementation note: AllowN is used (not ReserveN+Cancel) because Cancel
// only refunds tokens "as much as possible" — under concurrent load other
// reservations placed between Reserve and Cancel can hold tokens we
// thought we returned, accumulating phantom debt that over-throttles the
// account. AllowN is atomic: if a token isn't available it makes no
// reservation at all. We then peek at TokensAt for the Retry-After value,
// which is read-only and doesn't perturb state.
func (l *Limiter) Allow(accountID string) (bool, time.Duration) {
	if accountID == "" {
		return true, 0
	}
	now := time.Now()

	l.mu.Lock()
	e, ok := l.buckets[accountID]
	if !ok {
		e = &entry{
			limiter: rate.NewLimiter(rate.Limit(l.cfg.RPS), l.cfg.Burst),
		}
		l.buckets[accountID] = e
	}
	e.lastSeen = now
	l.mu.Unlock()

	if e.limiter.AllowN(now, 1) {
		return true, 0
	}
	// Denied. Compute Retry-After from the token deficit. TokensAt is a
	// pure read so this doesn't affect bucket state.
	deficit := 1.0 - e.limiter.TokensAt(now)
	if deficit < 0 {
		deficit = 0
	}
	retryAfter := time.Duration(deficit / l.cfg.RPS * float64(time.Second))
	if retryAfter < time.Millisecond {
		retryAfter = DefaultRetryAfter
	}
	if retryAfter > maxRetryAfter {
		retryAfter = maxRetryAfter
	}
	return false, retryAfter
}

// Prune drops buckets that haven't been touched within IdleEvict.
func (l *Limiter) Prune() int {
	cutoff := time.Now().Add(-l.cfg.IdleEvict)
	l.mu.Lock()
	defer l.mu.Unlock()
	dropped := 0
	for id, e := range l.buckets {
		if e.lastSeen.Before(cutoff) {
			delete(l.buckets, id)
			dropped++
		}
	}
	return dropped
}

// StartPruner launches a goroutine that calls Prune on PruneEvery cadence
// until ctx is cancelled. The goroutine is panic-safe via the provided
// recover function (typically saferun.Recover).
func (l *Limiter) StartPruner(ctx context.Context, logger *slog.Logger, recoverFn func()) {
	go func() {
		if recoverFn != nil {
			defer recoverFn()
		}
		ticker := time.NewTicker(l.cfg.PruneEvery)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				if dropped := l.Prune(); dropped > 0 && logger != nil {
					logger.Debug("rate limiter pruned idle accounts", "dropped", dropped)
				}
			}
		}
	}()
}

// Size returns the current number of tracked accounts. Intended for
// metrics / debug output.
func (l *Limiter) Size() int {
	l.mu.Lock()
	defer l.mu.Unlock()
	return len(l.buckets)
}
