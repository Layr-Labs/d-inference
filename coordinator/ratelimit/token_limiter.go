package ratelimit

import (
	"context"
	"hash/fnv"
	"log/slog"
	"sync"
	"time"
)

// tokenLockShards bounds the per-account lock table. Accounts hash to a shard;
// collisions only cause occasional, harmless extra serialization.
const tokenLockShards = 64

// TokenLimiter enforces per-account input-tokens-per-minute (ITPM) and
// output-tokens-per-minute (OTPM) limits using two token buckets. This is the
// industry-standard token-based throttle (cf. Anthropic ITPM/OTPM) that sits
// alongside the request-per-minute (RPM) limiter.
//
// Charges are clamped to each bucket's burst so a single large request can
// never be permanently rejected (a request needing more than the burst would
// otherwise never fit). The two-bucket peek+consume is serialized per account
// (sharded locks) so concurrent same-account requests can't both pass the peek
// and then over-admit or under-charge.
type TokenLimiter struct {
	input  *Limiter
	output *Limiter
	locks  [tokenLockShards]sync.Mutex
}

// lockFor returns the shard mutex guarding an account's peek+consume sequence.
func (t *TokenLimiter) lockFor(accountID string) *sync.Mutex {
	h := fnv.New32a()
	_, _ = h.Write([]byte(accountID))
	return &t.locks[h.Sum32()%tokenLockShards]
}

// NewTokenLimiter builds a TokenLimiter. Rates are in tokens per SECOND (the
// caller converts per-minute limits, e.g. ITPM/60). Bursts are bucket
// capacities and should be >= the largest single request's token count
// (typically >= max context for input and >= max output length for output).
//
// A dimension with a non-positive rate or burst is treated as UNLIMITED (its
// bucket is nil and that dimension is never enforced). This lets an operator
// disable just one dimension (e.g. ITPM enabled, OTPM=0) without it silently
// collapsing to New's default 1 tok/s.
func NewTokenLimiter(inputTokPerSec float64, inputBurst int, outputTokPerSec float64, outputBurst int) *TokenLimiter {
	t := &TokenLimiter{}
	if inputTokPerSec > 0 && inputBurst > 0 {
		t.input = New(Config{RPS: inputTokPerSec, Burst: inputBurst})
	}
	if outputTokPerSec > 0 && outputBurst > 0 {
		t.output = New(Config{RPS: outputTokPerSec, Burst: outputBurst})
	}
	return t
}

// Allow charges inputTokens to the input bucket and outputTokens to the output
// bucket. It peeks BOTH dimensions first and only consumes when both have
// capacity, so a rejection in one dimension never debits the other (an
// output-limited request must not drain the input budget). Returns the tripped
// dimension ("input_tokens" or "output_tokens") and a Retry-After hint when not
// allowed. Nil dimensions are unlimited; empty accountID is always allowed.
func (t *TokenLimiter) Allow(accountID string, inputTokens, outputTokens int) (allowed bool, dimension string, retryAfter time.Duration) {
	if accountID == "" {
		return true, "", 0
	}

	// Serialize this account's peek+consume so two concurrent requests can't
	// both pass the read-only CanN checks and then over-admit.
	lock := t.lockFor(accountID)
	lock.Lock()
	defer lock.Unlock()

	var in, out int
	if t.input != nil {
		in = clampCharge(inputTokens, t.input.Burst())
		if !t.input.CanN(accountID, in) {
			_, retry := t.input.AllowN(accountID, in) // fails atomically, no debit; yields Retry-After
			return false, "input_tokens", retry
		}
	}
	if t.output != nil {
		out = clampCharge(outputTokens, t.output.Burst())
		if !t.output.CanN(accountID, out) {
			_, retry := t.output.AllowN(accountID, out)
			return false, "output_tokens", retry
		}
	}
	// Both dimensions have capacity — consume now.
	if t.input != nil {
		t.input.AllowN(accountID, in)
	}
	if t.output != nil {
		t.output.AllowN(accountID, out)
	}
	return true, "", 0
}

// InputStat returns the input-token bucket snapshot for header emission and
// whether the dimension is enforced (false when unlimited).
func (t *TokenLimiter) InputStat(accountID string) (Stat, bool) {
	if t.input == nil {
		return Stat{}, false
	}
	return t.input.Stat(accountID), true
}

// OutputStat returns the output-token bucket snapshot and whether the dimension
// is enforced (false when unlimited).
func (t *TokenLimiter) OutputStat(accountID string) (Stat, bool) {
	if t.output == nil {
		return Stat{}, false
	}
	return t.output.Stat(accountID), true
}

// StartPruner launches idle-bucket pruning for any enforced dimensions.
func (t *TokenLimiter) StartPruner(ctx context.Context, logger *slog.Logger, recoverFn func()) {
	if t.input != nil {
		t.input.StartPruner(ctx, logger, recoverFn)
	}
	if t.output != nil {
		t.output.StartPruner(ctx, logger, recoverFn)
	}
}

// clampCharge bounds a token charge to [0, burst] so a request larger than the
// bucket can still pass once the bucket is full, rather than being rejected
// forever.
func clampCharge(n, burst int) int {
	if n < 0 {
		return 0
	}
	if n > burst {
		return burst
	}
	return n
}
