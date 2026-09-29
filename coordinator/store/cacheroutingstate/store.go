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
	// LoadCacheHolders returns up to limit rows that are live at now under the
	// current routing ttl. A row's effective expiry is the earlier of its
	// stored ExpiresAt and UpdatedAt+ttl (ttl <= 0 applies no clamp); rows
	// past it are skipped, ExpiresAt in the result carries the effective
	// value, and rows are ordered longest-lived first by that value. The
	// clamp runs before the limit, so a capped restore after a TTL reduction
	// keeps rows that are still valid rather than rows that only looked
	// long-lived under the old TTL. A limit of 0 or less means no limit.
	LoadCacheHolders(ctx context.Context, now time.Time, ttl time.Duration, limit int) ([]HolderRecord, error)
	// UpsertCacheDemand inserts or refreshes rows, keeping the later SeenAt.
	UpsertCacheDemand(context.Context, []DemandRecord) error
	// LoadCacheDemand returns up to limit rows whose SeenAt is at or after
	// notBefore, newest first. A limit of 0 or less means no limit.
	LoadCacheDemand(ctx context.Context, notBefore time.Time, limit int) ([]DemandRecord, error)
	// CacheRoutingKeyFingerprint returns the fingerprint of the derived cache
	// key generation the stored rows were written under, or "" when none was
	// recorded.
	CacheRoutingKeyFingerprint(ctx context.Context) (string, error)
	// ResetCacheRoutingState deletes every holder and demand row, whatever
	// their expiry, and then records fingerprint as the current key generation. Used when the master key
	// changed: rows derived under the old key can never match a request.
	ResetCacheRoutingState(ctx context.Context, fingerprint string) error
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
