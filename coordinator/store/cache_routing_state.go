package store

import (
	"context"
	"errors"
	"strings"
	"time"
)

// Cache routing state persistence.
//
// The registry keeps the exact prefix-cache holder index and the observed
// demand index in process memory, which is the serving copy. A coordinator
// restart used to drop both and pay 10–20 minutes of low hit rate while
// providers re-announced checkpoints one write at a time. These records are
// the durable copy: the registry writes them behind the in-memory index in
// small batches and reloads them at boot. Losing them costs hit rate for a few
// minutes, nothing else, so writes are best-effort and never on a request's
// critical path.
//
// A holder row is keyed by the opaque boundary key plus the provider's cache
// epoch rather than its connection-scoped provider ID: the epoch is minted per
// provider SSD root, persisted on the provider, and unique across the fleet, so
// a reconnecting provider (new provider ID, same epoch) can be matched to its
// rows. Rows carry no prompt content: keys and anchors are chained block
// hashes.

// CacheHolderKey identifies one durable holder row.
type CacheHolderKey struct {
	Key        string
	CacheEpoch string
}

// CacheHolderRecord is the durable form of one holder entry.
type CacheHolderRecord struct {
	Key                     string
	CacheEpoch              string
	Tier                    string
	ModelID                 string
	ModelAggregateHash      string
	PromptContractID        string
	BlockHashVersion        string
	AnchorChainHash         string
	AnchorTokenCount        int
	RequiredRecomputeTokens int
	StageMs                 float64
	UpdatedAt               time.Time
	ExpiresAt               time.Time
}

// HolderKey returns the row identity of the record.
func (r CacheHolderRecord) HolderKey() CacheHolderKey {
	return CacheHolderKey{Key: r.Key, CacheEpoch: r.CacheEpoch}
}

// CacheDemandRecord is the durable form of one observed-demand entry.
type CacheDemandRecord struct {
	Key    string
	SeenAt time.Time
}

// CacheRoutingStateStore is implemented by stores that can keep the cache
// routing indexes across coordinator restarts. Every method is safe to call
// with an empty slice.
type CacheRoutingStateStore interface {
	// UpsertCacheHolders inserts or refreshes rows. An existing row keeps the
	// later of the two UpdatedAt/ExpiresAt pairs.
	UpsertCacheHolders(context.Context, []CacheHolderRecord) error
	// DeleteCacheHolders removes rows; missing rows are not an error.
	DeleteCacheHolders(context.Context, []CacheHolderKey) error
	// LoadCacheHolders returns every row whose ExpiresAt is after now.
	LoadCacheHolders(ctx context.Context, now time.Time) ([]CacheHolderRecord, error)
	// UpsertCacheDemand inserts or refreshes rows, keeping the later SeenAt.
	UpsertCacheDemand(context.Context, []CacheDemandRecord) error
	// LoadCacheDemand returns every row whose SeenAt is at or after notBefore.
	LoadCacheDemand(ctx context.Context, notBefore time.Time) ([]CacheDemandRecord, error)
	// PruneCacheRoutingState deletes holders expired before now and demand
	// entries seen before demandNotBefore, in bounded batches, and returns
	// the number of rows removed.
	PruneCacheRoutingState(ctx context.Context, now, demandNotBefore time.Time) (int64, error)
}

// CacheRoutingStateBatchRows caps one multi-row statement so it stays far below
// PostgreSQL's bind-parameter ceiling (13 columns × 512 = 6,656 parameters).
const CacheRoutingStateBatchRows = 512

// cacheRoutingPruneBatchRows bounds one DELETE so pruning a 250k-row table
// never holds a long lock.
const cacheRoutingPruneBatchRows = 10_000

var errInvalidCacheRoutingRecord = errors.New("store: invalid cache routing record")

func (r CacheHolderRecord) validate() error {
	if strings.TrimSpace(r.Key) == "" || strings.TrimSpace(r.CacheEpoch) == "" ||
		strings.TrimSpace(r.ModelID) == "" || r.ExpiresAt.IsZero() || r.UpdatedAt.IsZero() {
		return errInvalidCacheRoutingRecord
	}
	return nil
}

func (r CacheDemandRecord) validate() error {
	if strings.TrimSpace(r.Key) == "" || r.SeenAt.IsZero() {
		return errInvalidCacheRoutingRecord
	}
	return nil
}

// laterHolder merges an incoming row into an existing one: the newer
// UpdatedAt wins and ExpiresAt never moves backwards, which makes a replayed or
// reordered batch idempotent.
func laterHolder(existing, incoming CacheHolderRecord) CacheHolderRecord {
	if incoming.UpdatedAt.Before(existing.UpdatedAt) {
		merged := existing
		if incoming.ExpiresAt.After(merged.ExpiresAt) {
			merged.ExpiresAt = incoming.ExpiresAt
		}
		return merged
	}
	merged := incoming
	if existing.ExpiresAt.After(merged.ExpiresAt) {
		merged.ExpiresAt = existing.ExpiresAt
	}
	return merged
}
