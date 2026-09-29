package promptwork

import (
	"context"

	"github.com/eigeninference/d-inference/coordinator/promptcontract"
)

// Account bounds all optional prompt accounting, including body parsing for
// calibrated fallback. Tokenizer unavailability does not skip the work bound.
// The caller's original deadline remains authoritative over the shorter cap.
func Account(ctx context.Context, gate *Gate, bodyBytes int, fallback Result, work func(context.Context) Result) Result {
	release, ok := gate.Acquire(ctx, bodyBytes)
	if !ok {
		return fallback
	}
	defer release()
	ctx, cancel := context.WithTimeout(ctx, promptcontract.DefaultRequestTimeout)
	defer cancel()
	if ctx.Err() != nil {
		return fallback
	}
	return work(ctx)
}
