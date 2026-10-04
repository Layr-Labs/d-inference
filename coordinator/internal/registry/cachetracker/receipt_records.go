package cachetracker

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

type SequenceKey struct {
	ProviderID string
	ModelID    string
	CacheEpoch string
	Tier       string
}

type FenceKey struct {
	ProviderID string
	ModelID    string
	Tier       string
}

// FenceRecord is a directory value. Updates replace it under the tracker lock;
// loading a value never exposes a mutable view into the retained directory.
type FenceRecord struct {
	Capability protocol.PrefixCacheV2Capability
	Until      time.Time
	Strikes    uint32
	Lapsed     bool
}

func (f FenceRecord) Active(now time.Time) bool { return now.Before(f.Until) }
func (f FenceRecord) Stale(now time.Time, retention time.Duration) bool {
	return !now.Before(f.Until.Add(retention))
}
