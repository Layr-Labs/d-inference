package api

import (
	"context"
	"hash/fnv"
	"math/rand"
)

// retryAfterJitterFraction is the maximum added jitter as a fraction of the
// base: result = base + floor(base × fraction × u), u ∈ [0, 1).
const retryAfterJitterFraction = 0.5

// retryAfterJitter returns the seconds added to base: floor(base × 0.5 × u)
// with u ∈ [0, 1) derived from a hash of requestID, so one request always gets
// the same answer and different requests spread over [base, 1.5 × base]. An
// empty id (call sites without a request in hand, or the profiler off) draws
// u at random — a constant key would leave every same-second 429 from those
// sites identical, which is exactly the herd the jitter exists to break.
//
// No coordinator 429/503 writer jittered before this: every rejection emitted
// in the same second carried the same integer, so an aggregator that re-fires
// each 429 after exactly Retry-After returned as a synchronized herd (the
// 2026-09-01 collapse: 4.4M coordinator-side vs 2.6M client requests).
func retryAfterJitter(base int, requestID string) int {
	if base <= 0 {
		return 0
	}
	var u float64
	if requestID == "" {
		u = rand.Float64() //nolint:gosec // jitter, not a secret
	} else {
		u = float64(requestIDHash(requestID)>>11) / float64(uint64(1)<<53)
	}
	return int(float64(base) * retryAfterJitterFraction * u)
}

// retryAfterJitterKey is the jitter key for a request: the COORDINATOR-minted
// correlation id (profiler.go), never the client-echoed X-Request-ID — a
// client re-sending a constant X-Request-ID across its burst would otherwise
// get identical jitter on every retry and the herd would not be broken.
// Empty (random jitter) when no middleware ran or the profiler is off.
func retryAfterJitterKey(ctx context.Context) string {
	return coordRequestIDFromContext(ctx)
}

// requestIDHash is FNV-1a 64 with a Murmur3 finalizer. Bare FNV-1a leaves the
// top bits of short, similar ids (uuid prefixes, "req-1".."req-99") clustered;
// the finalizer's avalanche makes the derived u uniform across such ids.
func requestIDHash(requestID string) uint64 {
	h := fnv.New64a()
	_, _ = h.Write([]byte(requestID))
	k := h.Sum64()
	k ^= k >> 33
	k *= 0xff51afd7ed558ccd
	k ^= k >> 33
	k *= 0xc4ceb9fe1a85ec53
	k ^= k >> 33
	return k
}
