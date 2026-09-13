package api

import (
	"context"
	"errors"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

// Preserve the first definitive response before attempting the ledger refund.
// A disconnected browser must not cancel this write. A stored rejection fences
// subsequent dispatches, so even a later refund failure is safe to retry.
func recordGlobalPayoutRejection(ctx context.Context, repo store.GlobalPayoutStore, id string, attempt int, code string) error {
	ctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 20*time.Second)
	defer cancel()
	var err error
	for retry := 0; retry < 3; retry++ {
		err = repo.RecordGlobalPayoutRejection(id, attempt, code)
		if err == nil || errors.Is(err, store.ErrPayoutConflict) || errors.Is(err, store.ErrNotFound) {
			return err
		}
		timer := time.NewTimer(time.Duration(retry+1) * 100 * time.Millisecond)
		select {
		case <-ctx.Done():
			timer.Stop()
			return ctx.Err()
		case <-timer.C:
		}
	}
	return err
}
