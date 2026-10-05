package cachetracker

import (
	"strings"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/cacheplan"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/cachepolicy"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// MaxAttemptBytes is the default logical-byte limit for one generation's
// retained attempt records, and the limit for any single retained string.
const MaxAttemptBytes uint64 = 64 << 20

// AttemptBudget is the logical-byte ledger of one generation's retained attempt
// records. The receipt controller serializes it under its existing mutex.
type AttemptBudget struct{ bytes, maxBytes uint64 }

func NewAttemptBudget(maxBytes uint64) *AttemptBudget {
	return &AttemptBudget{maxBytes: maxBytes}
}

func (b *AttemptBudget) Bytes() uint64      { return b.bytes }
func (b *AttemptBudget) MaxBytes() uint64   { return b.maxBytes }
func (b *AttemptBudget) Store(bytes uint64) { b.bytes = bytes }

// The memory tier's block geometry applies whenever that tier is usable.
func cacheAttemptBlockSize[P comparable](attempt Attempt[P]) uint32 {
	if attempt.MemoryCapability.Enabled && attempt.MemoryCapability.Ready {
		return attempt.MemoryCapability.BlockSize
	}
	return attempt.V2Capability.BlockSize
}

// This architecture-independent charge bounds retained tracker records, not
// allocator/RSS usage or the separately owned request, owner and holder state.
// Two future READY hashes are prepaid so receipt updates cannot grow the charge.
func CacheAttemptCharge[P comparable](nonce string, attempt Attempt[P]) (uint64, bool) {
	if nonce == "" || len(attempt.Plan.Boundaries) > cachepolicy.MaxReceiptTokens {
		return 0, false
	}
	n := len(attempt.Plan.Boundaries)
	blockSize := cacheAttemptBlockSize(attempt)
	if attempt.V2 {
		if blockSize == 0 || n == 0 || n > cachepolicy.MaxReceiptTokens/int(blockSize) ||
			!cachepolicy.Anchor(attempt.ExpectedPrompt, blockSize) ||
			attempt.ExpectedPrompt != attempt.Plan.Boundaries[n-1] ||
			attempt.Plan.PromptTokenCount < attempt.ExpectedPrompt.TokenCount {
			return 0, false
		}
	} else if n != 0 || attempt.ExpectedBoundaries.Len() != 0 {
		return 0, false
	}
	if attempt.ExpectedBoundaries != nil && attempt.ExpectedBoundaries.Len() != n {
		return 0, false
	}
	for _, anchor := range []protocol.PrefixCacheAnchor{attempt.LastReadyAnchor, attempt.MemoryLastReadyAnchor} {
		if anchor != (protocol.PrefixCacheAnchor{}) && !cachepolicy.Anchor(anchor, blockSize) {
			return 0, false
		}
	}
	structure, ok := CheckedCacheAttemptMultiply(96, uint64(n))
	if !ok {
		return 0, false
	}
	charge, ok := CheckedCacheAttemptAdd(2048+128, structure)
	if !ok {
		return 0, false
	}
	for _, boundary := range attempt.Plan.Boundaries {
		if !cachepolicy.Anchor(boundary, blockSize) || boundary.TokenCount > attempt.ExpectedPrompt.TokenCount {
			return 0, false
		}
		hashes, valid := CheckedCacheAttemptMultiply(2, uint64(len(boundary.ChainHash)))
		if !valid {
			return 0, false
		}
		charge, ok = CheckedCacheAttemptAdd(charge, hashes)
		if !ok {
			return 0, false
		}
	}
	// Fixed-size enumeration includes every retained variable scalar. Validate
	// lengths before a clone/map allocation; UTF-8 string sizes are byte lengths.
	for _, value := range []string{
		nonce, attempt.RequestID, attempt.ProviderID, attempt.Model,
		attempt.Plan.AffinityKey(), attempt.Plan.ModelAggregateHash,
		attempt.Plan.PromptContractID, attempt.Plan.CacheScope,
		attempt.ExpectedPrompt.ChainHash,
		attempt.V2Capability.ModelID, attempt.V2Capability.ModelAggregateHash,
		attempt.V2Capability.PromptContractID, attempt.V2Capability.BlockHashVersion,
		attempt.V2Capability.CacheEpoch, attempt.V2Capability.ReadyBoundaryMode,
		attempt.MemoryCapability.ModelID, attempt.MemoryCapability.ModelAggregateHash,
		attempt.MemoryCapability.PromptContractID, attempt.MemoryCapability.BlockHashVersion,
		attempt.MemoryCapability.CacheEpoch, attempt.MemoryCapability.ReadyBoundaryMode,
	} {
		if uint64(len(value)) > MaxAttemptBytes {
			return 0, false
		}
		charge, ok = CheckedCacheAttemptAdd(charge, uint64(len(value)))
		if !ok {
			return 0, false
		}
	}
	return charge, true
}

func CheckedCacheAttemptAdd(a, b uint64) (uint64, bool) {
	if b > ^uint64(0)-a {
		return 0, false
	}
	return a + b, true
}

func CheckedCacheAttemptMultiply(a, b uint64) (uint64, bool) {
	if a != 0 && b > ^uint64(0)/a {
		return 0, false
	}
	return a * b, true
}

// Called only after checked budget admission, while the receipt controller's
// mutex is held. Nil ExpectedBoundaries asks us to derive them. Supplied claims
// must agree exactly. No caller-owned strings, boundary slices or claims are
// retained by the tracker.
func detachCacheAttempt[P comparable](nonce string, attempt Attempt[P]) (string, Attempt[P], bool) {
	if attempt.ExpectedBoundaries != nil {
		for _, boundary := range attempt.Plan.Boundaries {
			if !attempt.ExpectedBoundaries.Matches(boundary) {
				return "", Attempt[P]{}, false
			}
		}
	}
	owned := attempt
	owned.RequestID = strings.Clone(attempt.RequestID)
	owned.ProviderID = strings.Clone(attempt.ProviderID)
	owned.Model = strings.Clone(attempt.Model)
	owned.Plan = attempt.Plan.Detached()
	// The frozen claims share the detached boundary hashes; a duplicate token
	// count is refused here.
	claims, valid := cacheplan.NewClaims(owned.Plan.Boundaries, cacheAttemptBlockSize(attempt), attempt.ExpectedPrompt)
	if !valid {
		return "", Attempt[P]{}, false
	}
	owned.ExpectedBoundaries = claims
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
