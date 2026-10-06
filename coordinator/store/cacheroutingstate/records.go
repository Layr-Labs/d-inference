// Package cacheroutingstate defines the durable copy of the coordinator's
// exact prefix-cache routing indexes.
//
// The registry keeps the holder index and the observed-demand index in process
// memory, which is the serving copy. A coordinator restart used to drop both
// and pay 10–20 minutes of low hit rate while providers re-announced
// checkpoints one write at a time. These records are the durable copy: the
// registry writes them behind the in-memory index in small batches and reloads
// them at boot. Losing them costs hit rate for a few minutes, nothing else, so
// writes are best-effort and never on a request's critical path.
//
// A holder row is keyed by the opaque boundary key plus the provider's cache
// epoch rather than its connection-scoped provider ID: the provider mints one
// epoch UUID per model SSD root, persists it, and it is unique across the
// fleet, so a reconnecting provider (new provider ID, same epoch) can be
// matched to its rows. Rows carry no prompt content: a key is an HMAC under
// the route key and an anchor is a token count.
package cacheroutingstate

import (
	"errors"
	"strings"
	"time"
)

// HolderKey identifies one durable holder row.
type HolderKey struct {
	Key        string
	CacheEpoch string
}

// HolderRecord is the durable form of one holder entry.
// A HolderRecord names a boundary only through Key, an HMAC under the route
// key: the provider-confirmed chain hash is never stored, so the durable copy
// holds no prompt-derived identifier an offline reader could match against a
// known prompt. A restored holder matches its plan boundary through the key.
type HolderRecord struct {
	Key                     string
	CacheEpoch              string
	Tier                    string
	ModelID                 string
	ModelAggregateHash      string
	PromptContractID        string
	BlockHashVersion        string
	ReadyBoundaryMode       string
	AnchorTokenCount        int
	RequiredRecomputeTokens int
	StageMs                 float64
	// MeasuredStageMs and MeasuredExpiresAt carry a lookup's measured stage
	// cost, which routing prefers over the Ready fallback (StageMs) until it
	// expires; zero when the holder has no live measurement.
	MeasuredStageMs   float64
	MeasuredExpiresAt time.Time
	UpdatedAt         time.Time
	ExpiresAt         time.Time
}

// HolderKey returns the row identity of the record.
func (r HolderRecord) HolderKey() HolderKey {
	return HolderKey{Key: r.Key, CacheEpoch: r.CacheEpoch}
}

// DemandRecord is the durable form of one observed-demand entry.
type DemandRecord struct {
	Key    string
	SeenAt time.Time
}

// ErrInvalidRecord rejects a row that could never be restored.
var ErrInvalidRecord = errors.New("cacheroutingstate: invalid record")

// Validate rejects rows without an identity or lifetime.
func (r HolderRecord) Validate() error {
	if strings.TrimSpace(r.Key) == "" || strings.TrimSpace(r.CacheEpoch) == "" ||
		strings.TrimSpace(r.ModelID) == "" || r.ExpiresAt.IsZero() || r.UpdatedAt.IsZero() {
		return ErrInvalidRecord
	}
	return nil
}

// Validate rejects rows without a key or observation time.
func (r DemandRecord) Validate() error {
	if strings.TrimSpace(r.Key) == "" || r.SeenAt.IsZero() {
		return ErrInvalidRecord
	}
	return nil
}
