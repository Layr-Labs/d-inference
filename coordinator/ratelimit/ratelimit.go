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
	"math"
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

// Limiter holds a token bucket per account.
type Limiter struct {
	cfg Config

	mu      sync.Mutex
	buckets map[string]*entry
}

type entry struct {
	limiter  *rate.Limiter
	lastSeen time.Time
	// rps/burst record the rate this bucket was configured with so callers
	// using per-key (variable-rate) buckets can detect a limit change and
	// reconcile the underlying token bucket. Zero for default-rate buckets.
	rps   float64
	burst int
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
	return l.AllowN(accountID, 1)
}

// AllowN reports whether n units (requests or tokens) may be consumed now. Used
// for token-per-minute limiting where one request consumes many units. If n
// exceeds the bucket's burst the call can never succeed, so callers that meter
// variable-size requests should clamp n to Burst() first.
//
// Empty accountID or n <= 0 is allowed unconditionally.
func (l *Limiter) AllowN(accountID string, n int) (bool, time.Duration) {
	if accountID == "" || n <= 0 {
		return true, 0
	}
	now := time.Now()
	e := l.bucketFor(accountID, now)

	if e.limiter.AllowN(now, n) {
		return true, 0
	}
	// Denied. Compute Retry-After from the token deficit. TokensAt is a
	// pure read so this doesn't affect bucket state.
	deficit := float64(n) - e.limiter.TokensAt(now)
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

// CanN reports whether n units are currently available for the account WITHOUT
// consuming them. Used for cross-bucket peek-then-consume so a rejection in one
// dimension doesn't debit another. Empty accountID or n <= 0 is always true.
// An unseen account is treated as a full bucket.
func (l *Limiter) CanN(accountID string, n int) bool {
	if accountID == "" || n <= 0 {
		return true
	}
	now := time.Now()
	l.mu.Lock()
	e, ok := l.buckets[accountID]
	l.mu.Unlock()
	if !ok {
		return n <= l.cfg.Burst
	}
	return e.limiter.TokensAt(now) >= float64(n)
}

// bucketFor returns the account's bucket, lazily creating it.
func (l *Limiter) bucketFor(accountID string, now time.Time) *entry {
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
	return e
}

// bucketForWithRate returns a bucket configured with a caller-supplied rate,
// lazily creating it and reconciling its rate/burst if the caller's per-key
// limit changed since the bucket was created. Used for per-key (variable-rate)
// limits where each key may carry a different ceiling.
func (l *Limiter) bucketForWithRate(key string, rps float64, burst int, now time.Time) *entry {
	l.mu.Lock()
	e, ok := l.buckets[key]
	if !ok {
		e = &entry{
			limiter: rate.NewLimiter(rate.Limit(rps), burst),
			rps:     rps,
			burst:   burst,
		}
		l.buckets[key] = e
	} else if e.rps != rps || e.burst != burst {
		e.limiter.SetLimit(rate.Limit(rps))
		e.limiter.SetBurst(burst)
		e.rps = rps
		e.burst = burst
	}
	e.lastSeen = now
	l.mu.Unlock()
	return e
}

// AllowNWithRate consumes n units against a per-key bucket configured with the
// given per-key rate (units/sec) and burst. A non-positive rps or burst is
// treated as UNLIMITED (always allowed). n is clamped to burst so a single
// oversized request can still pass once the bucket is full. Empty key or n<=0
// is always allowed.
func (l *Limiter) AllowNWithRate(key string, n int, rps float64, burst int) (bool, time.Duration) {
	if key == "" || n <= 0 || rps <= 0 || burst <= 0 {
		return true, 0
	}
	if n > burst {
		n = burst
	}
	now := time.Now()
	e := l.bucketForWithRate(key, rps, burst, now)
	if e.limiter.AllowN(now, n) {
		return true, 0
	}
	deficit := float64(n) - e.limiter.TokensAt(now)
	if deficit < 0 {
		deficit = 0
	}
	retryAfter := time.Duration(deficit / rps * float64(time.Second))
	if retryAfter < time.Millisecond {
		retryAfter = DefaultRetryAfter
	}
	if retryAfter > maxRetryAfter {
		retryAfter = maxRetryAfter
	}
	return false, retryAfter
}

// CanNWithRate reports whether n units are currently available against a per-key
// bucket at the given rate WITHOUT consuming. Ensures the bucket exists at the
// requested rate. Non-positive rps/burst is unlimited (always true).
func (l *Limiter) CanNWithRate(key string, n int, rps float64, burst int) bool {
	if key == "" || n <= 0 || rps <= 0 || burst <= 0 {
		return true
	}
	if n > burst {
		n = burst
	}
	now := time.Now()
	e := l.bucketForWithRate(key, rps, burst, now)
	return e.limiter.TokensAt(now) >= float64(n)
}

// RPS returns the configured sustained rate (units per second).
func (l *Limiter) RPS() float64 { return l.cfg.RPS }

// Burst returns the configured bucket capacity.
func (l *Limiter) Burst() int { return l.cfg.Burst }

// Stat is a point-in-time snapshot of an account's limiter state, shaped for
// the standard x-ratelimit-* response headers. LimitPerMinute reports the
// sustained rate as a per-minute figure (RPS*60); Remaining is the current
// bucket level; ResetSeconds is the time to fully replenish the bucket.
type Stat struct {
	LimitPerMinute int
	Remaining      int
	ResetSeconds   int
}

// Stat returns the current limiter snapshot for an account without consuming.
func (l *Limiter) Stat(accountID string) Stat {
	now := time.Now()
	rem := float64(l.cfg.Burst)
	if accountID != "" {
		l.mu.Lock()
		e, ok := l.buckets[accountID]
		l.mu.Unlock()
		if ok {
			rem = e.limiter.TokensAt(now)
		}
	}
	if rem < 0 {
		rem = 0
	}
	deficit := float64(l.cfg.Burst) - rem
	if deficit < 0 {
		deficit = 0
	}
	resetSec := 0
	if l.cfg.RPS > 0 {
		resetSec = int(math.Ceil(deficit / l.cfg.RPS))
	}
	return Stat{
		LimitPerMinute: int(math.Round(l.cfg.RPS * 60)),
		Remaining:      int(rem),
		ResetSeconds:   resetSec,
	}
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
