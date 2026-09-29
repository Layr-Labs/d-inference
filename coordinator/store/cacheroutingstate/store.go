package cacheroutingstate

import (
	"context"
	"time"
)

// Store is implemented by stores that can keep the cache routing indexes
// across coordinator restarts. Every method is safe to call with an empty
// slice. Method names carry the "Cache" prefix because the implementations
// live on the shared store types next to unrelated methods.
type Store interface {
	// UpsertCacheHolders inserts or refreshes rows. An existing row keeps the
	// newer receipt's descriptive columns and the later of the two expiries.
	UpsertCacheHolders(context.Context, []HolderRecord) error
	// DeleteCacheHolders removes rows; missing rows are not an error.
	DeleteCacheHolders(context.Context, []HolderKey) error
	// LoadCacheHolders returns up to limit rows whose ExpiresAt is after now,
	// longest-lived first, so a capped restore keeps the most valuable rows.
	// A limit of 0 or less means no limit.
	LoadCacheHolders(ctx context.Context, now time.Time, limit int) ([]HolderRecord, error)
	// UpsertCacheDemand inserts or refreshes rows, keeping the later SeenAt.
	UpsertCacheDemand(context.Context, []DemandRecord) error
	// LoadCacheDemand returns every row whose SeenAt is at or after notBefore.
	LoadCacheDemand(ctx context.Context, notBefore time.Time) ([]DemandRecord, error)
	// PruneCacheRoutingState deletes holders expired before now and demand
	// entries seen before demandNotBefore, in bounded batches, and returns
	// the number of rows removed.
	PruneCacheRoutingState(ctx context.Context, now, demandNotBefore time.Time) (int64, error)
}

// BatchRows caps one multi-row statement so it stays far below PostgreSQL's
// bind-parameter ceiling (13 columns × 512 = 6,656 parameters).
const BatchRows = 512

// PruneBatchRows bounds one DELETE so pruning a 250k-row table never holds a
// long lock.
const PruneBatchRows = 10_000
