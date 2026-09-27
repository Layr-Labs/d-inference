package registry

import (
	"strings"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// This architecture-independent charge bounds retained tracker records, not
// allocator/RSS usage or the separately owned request, owner and holder state.
// Two future READY hashes are prepaid so receipt updates cannot grow the charge.
func cacheAttemptCharge(nonce string, attempt cacheAttempt) (uint64, bool) {
	if nonce == "" || len(attempt.Plan.Boundaries) > cacheRoutingMaxReceiptTokens {
		return 0, false
	}
	n := len(attempt.Plan.Boundaries)
	blockSize := attempt.V2Capability.BlockSize
	if attempt.MemoryCapability.Enabled && attempt.MemoryCapability.Ready {
		blockSize = attempt.MemoryCapability.BlockSize
	}
	if attempt.V2 {
		if blockSize == 0 || n == 0 || n > cacheRoutingMaxReceiptTokens/int(blockSize) ||
			!validV2Anchor(attempt.ExpectedPrompt, blockSize) ||
			attempt.ExpectedPrompt != attempt.Plan.Boundaries[n-1] ||
			attempt.Plan.PromptTokenCount < attempt.ExpectedPrompt.TokenCount {
			return 0, false
		}
	} else if n != 0 || len(attempt.ExpectedBoundaries) != 0 {
		return 0, false
	}
	if attempt.ExpectedBoundaries != nil && len(attempt.ExpectedBoundaries) != n {
		return 0, false
	}
	for _, anchor := range []protocol.PrefixCacheAnchor{attempt.LastReadyAnchor, attempt.MemoryLastReadyAnchor} {
		if anchor != (protocol.PrefixCacheAnchor{}) && !validV2Anchor(anchor, blockSize) {
			return 0, false
		}
	}
	structure, ok := checkedCacheAttemptMultiply(96, uint64(n))
	if !ok {
		return 0, false
	}
	charge, ok := checkedCacheAttemptAdd(2048+128, structure)
	if !ok {
		return 0, false
	}
	for _, boundary := range attempt.Plan.Boundaries {
		if !validV2Anchor(boundary, blockSize) || boundary.TokenCount > attempt.ExpectedPrompt.TokenCount {
			return 0, false
		}
		hashes, valid := checkedCacheAttemptMultiply(2, uint64(len(boundary.ChainHash)))
		if !valid {
			return 0, false
		}
		charge, ok = checkedCacheAttemptAdd(charge, hashes)
		if !ok {
			return 0, false
		}
	}
	// Fixed-size enumeration includes every retained variable scalar. Validate
	// lengths before a clone/map allocation; UTF-8 string sizes are byte lengths.
	for _, value := range []string{
		nonce, attempt.RequestID, attempt.ProviderID, attempt.Model,
		attempt.Plan.affinityKey, attempt.Plan.ModelAggregateHash,
		attempt.Plan.PromptContractID, attempt.Plan.CacheScope,
		attempt.ExpectedPrompt.ChainHash,
		attempt.V2Capability.ModelID, attempt.V2Capability.ModelAggregateHash,
		attempt.V2Capability.PromptContractID, attempt.V2Capability.BlockHashVersion,
		attempt.V2Capability.CacheEpoch, attempt.V2Capability.ReadyBoundaryMode,
		attempt.MemoryCapability.ModelID, attempt.MemoryCapability.ModelAggregateHash,
		attempt.MemoryCapability.PromptContractID, attempt.MemoryCapability.BlockHashVersion,
		attempt.MemoryCapability.CacheEpoch, attempt.MemoryCapability.ReadyBoundaryMode,
	} {
		if uint64(len(value)) > cacheRoutingMaxAttemptBytes {
			return 0, false
		}
		charge, ok = checkedCacheAttemptAdd(charge, uint64(len(value)))
		if !ok {
			return 0, false
		}
	}
	return charge, true
}

func checkedCacheAttemptAdd(a, b uint64) (uint64, bool) {
	if b > ^uint64(0)-a {
		return 0, false
	}
	return a + b, true
}

func checkedCacheAttemptMultiply(a, b uint64) (uint64, bool) {
	if a != 0 && b > ^uint64(0)/a {
		return 0, false
	}
	return a * b, true
}

// Called only after checked budget admission, while tracker.mu is held. A nil
// ExpectedBoundaries asks us to derive it. A supplied map must agree exactly.
// No caller-owned strings, boundary slices or maps are retained by the tracker.
func detachCacheAttempt(nonce string, attempt cacheAttempt) (string, cacheAttempt, bool) {
	owned := attempt
	owned.RequestID = strings.Clone(attempt.RequestID)
	owned.ProviderID = strings.Clone(attempt.ProviderID)
	owned.Model = strings.Clone(attempt.Model)
	owned.Plan.affinityKey = strings.Clone(attempt.Plan.affinityKey)
	owned.Plan.ModelAggregateHash = strings.Clone(attempt.Plan.ModelAggregateHash)
	owned.Plan.PromptContractID = strings.Clone(attempt.Plan.PromptContractID)
	owned.Plan.CacheScope = strings.Clone(attempt.Plan.CacheScope)
	owned.Plan.Boundaries = make([]protocol.PrefixCacheAnchor, len(attempt.Plan.Boundaries))
	owned.ExpectedBoundaries = make(map[int]string, len(attempt.Plan.Boundaries))
	for i, boundary := range attempt.Plan.Boundaries {
		if _, duplicate := owned.ExpectedBoundaries[boundary.TokenCount]; duplicate {
			return "", cacheAttempt{}, false
		}
		if attempt.ExpectedBoundaries != nil && attempt.ExpectedBoundaries[boundary.TokenCount] != boundary.ChainHash {
			return "", cacheAttempt{}, false
		}
		boundary.ChainHash = strings.Clone(boundary.ChainHash)
		owned.Plan.Boundaries[i] = boundary
		owned.ExpectedBoundaries[boundary.TokenCount] = boundary.ChainHash
	}
	owned.ExpectedPrompt.ChainHash = strings.Clone(attempt.ExpectedPrompt.ChainHash)
	owned.LastReadyAnchor.ChainHash = strings.Clone(attempt.LastReadyAnchor.ChainHash)
	owned.MemoryLastReadyAnchor.ChainHash = strings.Clone(attempt.MemoryLastReadyAnchor.ChainHash)
	owned.V2Capability = detachCacheCapability(attempt.V2Capability)
	owned.MemoryCapability = detachCacheCapability(attempt.MemoryCapability)
	return strings.Clone(nonce), owned, true
}

func detachCacheCapability(capability protocol.PrefixCacheV2Capability) protocol.PrefixCacheV2Capability {
	capability.ModelID = strings.Clone(capability.ModelID)
	capability.ModelAggregateHash = strings.Clone(capability.ModelAggregateHash)
	capability.PromptContractID = strings.Clone(capability.PromptContractID)
	capability.BlockHashVersion = strings.Clone(capability.BlockHashVersion)
	capability.CacheEpoch = strings.Clone(capability.CacheEpoch)
	capability.ReadyBoundaryMode = strings.Clone(capability.ReadyBoundaryMode)
	return capability
}
