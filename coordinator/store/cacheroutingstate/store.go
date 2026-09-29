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
	// current routing ttl and were not updated more than FutureSkew after now
	// (a previous instance's fast clock); a row inside that tolerance loads
	// with UpdatedAt clamped to now (its effective expiry is computed from
	// the stored, unclamped time). A row's effective expiry is the earlier of its
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
	// notBefore and at most FutureSkew after notAfter, newest first, with a
	// SeenAt past notAfter clamped to it. The upper bound keeps rows stamped
	// well ahead by a previous instance's fast clock from taking the cap
	// ahead of valid rows. A limit of 0 or less means no limit.
	LoadCacheDemand(ctx context.Context, notBefore, notAfter time.Time, limit int) ([]DemandRecord, error)
	// CacheRoutingKeyFingerprint returns the fingerprint of the derived cache
	// key generation the stored rows were written under, or "" when none was
	// recorded.
	CacheRoutingKeyFingerprint(ctx context.Context) (string, error)
	// ResetCacheRoutingState records ResetInProgress as the key generation,
	// then deletes every holder and demand row, whatever their expiry, and
	// then records fingerprint as the generation. A reset interrupted
	// between its batched deletes (a crash, a shutdown deadline) therefore
	// leaves the marker behind, and the next boot repeats the reset instead
	// of restoring the residual rows. Used when the key generation changed
	// (rows derived under the old keys can never match a request) and when
	// the persister's delete backlog overflowed, under the same generation,
	// where only the marker tells an interrupted reset from a complete one.
	ResetCacheRoutingState(ctx context.Context, fingerprint string) error
	// PruneCacheRoutingState deletes holders whose effective expiry under ttl
	// (the earlier of the stored expiry and UpdatedAt+ttl; ttl <= 0 applies no
	// clamp) is not after now, and demand entries seen before demandNotBefore,
	// in bounded batches, and returns the number of rows removed. Pruning
	// under the active TTL keeps rows written under a longer one from
	// outliving today's setting in the table after they stopped loading.
	// Rows stamped more than FutureSkew ahead of now (a previous instance's
	// clock ran ahead) are removed too: loads quarantine them, and the merge
	// would otherwise let their future timestamps outrank every current
	// receipt for the same row until the clock caught up.
	PruneCacheRoutingState(ctx context.Context, now time.Time, ttl time.Duration, demandNotBefore time.Time) (int64, error)
}

// BatchRows caps one multi-row statement so it stays far below PostgreSQL's
// bind-parameter ceiling (13 columns × 512 = 6,656 parameters).
const BatchRows = 512

// PruneBatchRows bounds one DELETE so pruning a 250k-row table never holds a
// long lock.
const PruneBatchRows = 10_000

// FutureSkew is how far ahead of the pruning clock a row's timestamp may be
// before the prune treats it as another instance's skew and removes it.
const FutureSkew = time.Minute

// ResetInProgress is the key generation recorded while ResetCacheRoutingState
// clears the tables; a boot that reads it completes the interrupted reset.
const ResetInProgress = "reset-in-progress"
