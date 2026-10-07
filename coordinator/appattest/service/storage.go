package service

import (
	"context"
	"time"

	recovery "github.com/eigeninference/d-inference/coordinator/internal/appattest/recovery"
	storagebudget "github.com/eigeninference/d-inference/coordinator/internal/appattest/storage"
)

// acquireStorage bounds proof-related shadow session database work, including rejected
// proofs, deferred archive completion, standalone events, and enrollment writes.
// It never waits for the shared pool. Inventory and receipt renewal retain their
// separate worker limits; optional lifecycle reads use diagnosticSlots.
// Nested observations reuse the session's permit.
// Only the serialized session worker may call this method.
func (x *Session) acquireStorage() (release func(), ok bool) {
	return x.storageAdmission().Acquire()
}

func (x *Session) storageAdmission() *storagebudget.Scope {
	if x.storageScope == nil {
		x.storageScope = storagebudget.NewScope(x.s.shadowStorageBudget())
	}
	return x.storageScope
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
		if !time.Now().Before(deadline) || !recovery.Wait(ctx, 50*time.Millisecond) {
			return nil, false
		}
	}
}
