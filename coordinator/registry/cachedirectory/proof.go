package cachedirectory

import (
	"math"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func ValidLowerHex256(value string) bool {
	if len(value) != 64 {
		return false
	}
	for _, r := range value {
		if (r < '0' || r > '9') && (r < 'a' || r > 'f') {
			return false
		}
	}
	return true
}

func (t *Directory[C]) CapabilityRejected(
	providerID, modelID, tier string,
	capability protocol.PrefixCacheV2Capability,
) bool {
	key := cacheV2ProviderModelKey{ProviderID: providerID, ModelID: modelID, Tier: tier}
	t.mu.Lock()
	defer t.mu.Unlock()
	rejected, ok := t.rejectedV2[key]
	if ok && rejected != capability {
		delete(t.rejectedV2, key)
		return false
	}
	return ok
}

func (t *Directory[C]) RejectCapability(
	providerID, modelID, tier string,
	capability protocol.PrefixCacheV2Capability,
) bool {
	t.mu.Lock()
	defer t.mu.Unlock()
	if t.generation.Revoked() {
		return false
	}
	t.rejectedV2[cacheV2ProviderModelKey{
		ProviderID: providerID,
		ModelID:    modelID,
		Tier:       tier,
	}] = capability
	return true
}

func (t *Directory[C]) acceptV2SequenceLocked(
	providerID string,
	capability protocol.PrefixCacheV2Capability,
	tier string,
	sequence uint64,
) bool {
	if sequence == 0 || t.generation.Revoked() {
		return false
	}
	key := cacheV2SequenceKey{
		ProviderID: providerID,
		ModelID:    capability.ModelID,
		CacheEpoch: capability.CacheEpoch,
		Tier:       tier,
	}
	if sequence <= t.v2Sequences[key] {
		return false
	}
	t.v2Sequences[key] = sequence
	return true
}

func v2IdentityMatches(
	modelID, aggregateHash, contractID, epoch string,
	capability protocol.PrefixCacheV2Capability,
) bool {
	return modelID == capability.ModelID &&
		aggregateHash == capability.ModelAggregateHash &&
		contractID == capability.PromptContractID &&
		epoch == capability.CacheEpoch &&
		capability.Enabled &&
		capability.Ready
}

func ValidAnchor(anchor protocol.PrefixCacheAnchor, blockSize uint32) bool {
	return blockSize > 0 &&
		anchor.TokenCount > 0 &&
		anchor.TokenCount <= MaxReceiptTokens &&
		anchor.TokenCount%int(blockSize) == 0 &&
		ValidLowerHex256(anchor.ChainHash)
}

func validV2Stage(stage float64) bool {
	return stage >= 0 &&
		stage <= MaxStageMs &&
		!math.IsNaN(stage) &&
		!math.IsInf(stage, 0)
}
