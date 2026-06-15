package ratelimit

import (
	"context"
	"hash/fnv"
	"log/slog"
	"sync"
	"time"
)

// KeyTokenLimiter enforces per-API-key input/output token-per-minute limits
// where each key may carry a DIFFERENT rate (unlike TokenLimiter, whose rates
// are fixed per tier). It is the per-key override layer that sits alongside the
// per-account TokenLimiter.
//
// Rates and bursts are supplied per call (sourced from the key's own limit
// fields). A dimension with a non-positive rate or burst is unlimited for that
// call. The two-bucket peek+consume is serialized per key (sharded locks) so a
// rejection in one dimension never debits the other and concurrent same-key
// requests can't over-admit.
type KeyTokenLimiter struct {
	input  *Limiter
	output *Limiter
	locks  [tokenLockShards]sync.Mutex
}

// NewKeyTokenLimiter constructs an empty per-key token limiter. The underlying
// buckets are created lazily per key at the key's configured rate.
func NewKeyTokenLimiter() *KeyTokenLimiter {
	return &KeyTokenLimiter{
		input:  New(Config{RPS: DefaultRPS, Burst: DefaultBurst}),
		output: New(Config{RPS: DefaultRPS, Burst: DefaultBurst}),
	}
}

func (t *KeyTokenLimiter) lockFor(key string) *sync.Mutex {
	h := fnv.New32a()
	_, _ = h.Write([]byte(key))
	return &t.locks[h.Sum32()%tokenLockShards]
}

// StartPruner launches idle-bucket pruning for both token dimensions.
func (t *KeyTokenLimiter) StartPruner(ctx context.Context, logger *slog.Logger, recoverFn func()) {
	t.input.StartPruner(ctx, logger, recoverFn)
	t.output.StartPruner(ctx, logger, recoverFn)
}

// Allow charges inputTokens/outputTokens against the key's per-key token
// buckets at the supplied per-key rates. inRPS/outRPS are tokens-per-second
// (caller converts ITPM/OTPM / 60); bursts should be >= the key's per-minute
// allotment. A non-positive rate/burst means that dimension is unlimited.
// Returns the tripped dimension and a Retry-After hint when not allowed.
func (t *KeyTokenLimiter) Allow(key string, inputTokens, outputTokens int,
	inRPS float64, inBurst int, outRPS float64, outBurst int) (allowed bool, dimension string, retryAfter time.Duration) {
	if key == "" {
		return true, "", 0
	}
	inputEnforced := inRPS > 0 && inBurst > 0
	outputEnforced := outRPS > 0 && outBurst > 0
	if !inputEnforced && !outputEnforced {
		return true, "", 0
	}

	lock := t.lockFor(key)
	lock.Lock()
	defer lock.Unlock()

	if inputEnforced {
		if !t.input.CanNWithRate(key, inputTokens, inRPS, inBurst) {
			_, retry := t.input.AllowNWithRate(key, inputTokens, inRPS, inBurst)
			return false, "input_tokens", retry
		}
	}
	if outputEnforced {
		if !t.output.CanNWithRate(key, outputTokens, outRPS, outBurst) {
			_, retry := t.output.AllowNWithRate(key, outputTokens, outRPS, outBurst)
			return false, "output_tokens", retry
		}
	}
	if inputEnforced {
		t.input.AllowNWithRate(key, inputTokens, inRPS, inBurst)
	}
	if outputEnforced {
		t.output.AllowNWithRate(key, outputTokens, outRPS, outBurst)
	}
	return true, "", 0
}

// Peek reports whether a charge would be admitted WITHOUT consuming tokens, so
// the caller can peek this limiter and the account-level limiter together and
// only Commit when both pass (no drain on the other's rejection).
func (t *KeyTokenLimiter) Peek(key string, inputTokens, outputTokens int,
	inRPS float64, inBurst int, outRPS float64, outBurst int) (ok bool, dimension string, retryAfter time.Duration) {
	if key == "" {
		return true, "", 0
	}
	inputEnforced := inRPS > 0 && inBurst > 0
	outputEnforced := outRPS > 0 && outBurst > 0
	if !inputEnforced && !outputEnforced {
		return true, "", 0
	}

	lock := t.lockFor(key)
	lock.Lock()
	defer lock.Unlock()

	if inputEnforced && !t.input.CanNWithRate(key, inputTokens, inRPS, inBurst) {
		_, retry := t.input.AllowNWithRate(key, inputTokens, inRPS, inBurst)
		return false, "input_tokens", retry
	}
	if outputEnforced && !t.output.CanNWithRate(key, outputTokens, outRPS, outBurst) {
		_, retry := t.output.AllowNWithRate(key, outputTokens, outRPS, outBurst)
		return false, "output_tokens", retry
	}
	return true, "", 0
}

// Commit consumes a charge that a prior Peek confirmed would fit.
func (t *KeyTokenLimiter) Commit(key string, inputTokens, outputTokens int,
	inRPS float64, inBurst int, outRPS float64, outBurst int) {
	if key == "" {
		return
	}
	lock := t.lockFor(key)
	lock.Lock()
	defer lock.Unlock()
	if inRPS > 0 && inBurst > 0 {
		t.input.AllowNWithRate(key, inputTokens, inRPS, inBurst)
	}
	if outRPS > 0 && outBurst > 0 {
		t.output.AllowNWithRate(key, outputTokens, outRPS, outBurst)
	}
}

func (t *KeyTokenLimiter) DebitOutput(key string, outputTokens int, outRPS float64, outBurst int) {
	if key == "" || outputTokens <= 0 || outRPS <= 0 || outBurst <= 0 {
		return
	}
	lock := t.lockFor(key)
	lock.Lock()
	defer lock.Unlock()
	t.output.DebitNWithRate(key, outputTokens, outRPS, outBurst)
}
