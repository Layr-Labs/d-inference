package ratelimit

import (
	"context"
	"log/slog"
	"time"
)

// TokenLimiter enforces per-account input-tokens-per-minute (ITPM) and
// output-tokens-per-minute (OTPM) limits using two token buckets. This is the
// industry-standard token-based throttle (cf. Anthropic ITPM/OTPM) that sits
// alongside the request-per-minute (RPM) limiter.
//
// Charges are clamped to each bucket's burst so a single large request can
// never be permanently rejected (a request needing more than the burst would
// otherwise never fit). Input is metered before output; if the input bucket
// rejects, no output tokens are consumed.
type TokenLimiter struct {
	input  *Limiter
	output *Limiter
}

// NewTokenLimiter builds a TokenLimiter. Rates are in tokens per SECOND (the
// caller converts per-minute limits, e.g. ITPM/60). Bursts are bucket
// capacities and should be >= the largest single request's token count
// (typically >= max context for input and >= max output length for output).
func NewTokenLimiter(inputTokPerSec float64, inputBurst int, outputTokPerSec float64, outputBurst int) *TokenLimiter {
	return &TokenLimiter{
		input:  New(Config{RPS: inputTokPerSec, Burst: inputBurst}),
		output: New(Config{RPS: outputTokPerSec, Burst: outputBurst}),
	}
}

// Allow consumes inputTokens from the input bucket and outputTokens from the
// output bucket. Returns the tripped dimension ("input_tokens" or
// "output_tokens") and a Retry-After hint when not allowed. Empty accountID is
// allowed unconditionally.
func (t *TokenLimiter) Allow(accountID string, inputTokens, outputTokens int) (allowed bool, dimension string, retryAfter time.Duration) {
	if accountID == "" {
		return true, "", 0
	}
	in := clampCharge(inputTokens, t.input.Burst())
	if ok, retry := t.input.AllowN(accountID, in); !ok {
		return false, "input_tokens", retry
	}
	out := clampCharge(outputTokens, t.output.Burst())
	if ok, retry := t.output.AllowN(accountID, out); !ok {
		return false, "output_tokens", retry
	}
	return true, "", 0
}

// InputStat returns the input-token bucket snapshot for header emission.
func (t *TokenLimiter) InputStat(accountID string) Stat { return t.input.Stat(accountID) }

// OutputStat returns the output-token bucket snapshot for header emission.
func (t *TokenLimiter) OutputStat(accountID string) Stat { return t.output.Stat(accountID) }

// StartPruner launches idle-bucket pruning for both underlying buckets.
func (t *TokenLimiter) StartPruner(ctx context.Context, logger *slog.Logger, recoverFn func()) {
	t.input.StartPruner(ctx, logger, recoverFn)
	t.output.StartPruner(ctx, logger, recoverFn)
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
