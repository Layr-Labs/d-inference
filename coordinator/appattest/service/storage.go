package service

import (
	"context"
	"time"
)

// acquireStorage bounds all shadow session database work, including rejected
// proofs, deferred archive completion, standalone events, and enrollment writes.
// It never waits for the shared pool. Inventory and receipt renewal retain their
// separate worker limits. Nested observations reuse the session's permit.
// Only the serialized session worker may call this method.
func (x *Session) acquireStorage() (release func(), ok bool) {
	if x.storageSlotHeld {
		return func() {}, true
	}
	x.s.storageOnce.Do(func() {
		x.s.storageSlots = make(chan struct{}, 4)
	})
	select {
	case x.s.storageSlots <- struct{}{}:
		x.storageSlotHeld = true
		return func() {
			x.storageSlotHeld = false
			<-x.s.storageSlots
		}, true
	default:
		return nil, false
	}
}

// acquireStorageWithin retries acquireStorage for up to limit. Only work that
// runs before a session's first exchange may wait: no proof or response
// deadline is pending yet.
func (x *Session) acquireStorageWithin(ctx context.Context, limit time.Duration) (release func(), ok bool) {
	deadline := time.Now().Add(limit)
	for {
		if release, ok := x.acquireStorage(); ok {
			return release, true
		}
		if !time.Now().Before(deadline) || !waitAppAttestRetry(ctx, 50*time.Millisecond) {
			return nil, false
		}
	}
}
