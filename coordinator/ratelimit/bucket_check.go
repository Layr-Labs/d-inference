package ratelimit

import (
	"time"

	"golang.org/x/time/rate"
)

// CheckN returns availability and a retry hint without consuming tokens.
// Callers coordinating several buckets must hold their transaction lock across
// all checks and the subsequent charges.
func (l *Limiter) CheckN(accountID string, n int) (bool, time.Duration) {
	if accountID == "" || n <= 0 {
		return true, 0
	}
	now := time.Now()
	return checkBucket(l.bucketFor(accountID, now).limiter, now, n, l.cfg.RPS, l.cfg.Burst)
}

// CheckNWithRate is the per-key counterpart, with the same unlimited and
// oversized-charge rules as AllowNWithRate.
func (l *Limiter) CheckNWithRate(key string, n int, rps float64, burst int) (bool, time.Duration) {
	if key == "" || n <= 0 || rps <= 0 || burst <= 0 {
		return true, 0
	}
	n = min(n, burst)
	now := time.Now()
	return checkBucket(l.bucketForWithRate(key, rps, burst, now).limiter, now, n, rps, burst)
}

func checkBucket(bucket *rate.Limiter, now time.Time, n int, rps float64, burst int) (bool, time.Duration) {
	available := bucket.TokensAt(now)
	if n <= burst && available >= float64(n) {
		return true, 0
	}
	deficit := max(float64(n)-available, 0)
	retry := time.Duration(deficit / rps * float64(time.Second))
	if retry < time.Millisecond {
		retry = DefaultRetryAfter
	}
	return false, min(retry, maxRetryAfter)
}
