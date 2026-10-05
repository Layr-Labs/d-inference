package cachetracker

import (
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func (t *Tracker[P]) AcceptV2SequenceLocked(
	providerID string,
	capability protocol.PrefixCacheV2Capability,
	tier string,
	sequence uint64,
) bool {
	if sequence == 0 || !t.generation.Active() {
		return false
	}
	key := SequenceKey{
		ProviderID: providerID,
		ModelID:    capability.ModelID,
		CacheEpoch: capability.CacheEpoch,
		Tier:       tier,
	}
	if sequence <= t.v2Sequences.Lookup(key) {
		return false
	}
	t.v2Sequences.Store(key, sequence)
	return true
}
