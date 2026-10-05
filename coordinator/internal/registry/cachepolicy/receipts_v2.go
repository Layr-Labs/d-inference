package cachepolicy

import (
	"math"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func IdentityMatches(
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

func Anchor(anchor protocol.PrefixCacheAnchor, blockSize uint32) bool {
	return blockSize > 0 &&
		anchor.TokenCount > 0 &&
		anchor.TokenCount <= MaxReceiptTokens &&
		anchor.TokenCount%int(blockSize) == 0 &&
		LowerHex256(anchor.ChainHash)
}

func Stage(stage float64) bool {
	return stage >= 0 &&
		stage <= MaxStageMs &&
		!math.IsNaN(stage) &&
		!math.IsInf(stage, 0)
}
