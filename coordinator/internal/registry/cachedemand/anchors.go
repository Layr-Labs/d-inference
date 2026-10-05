package cachedemand

import (
	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"slices"
)

const (
	StrideTokens        = 4 * int(promptcontract.BlockSize)
	MaxStrideBoundaries = 64
	MaxLadderBoundaries = 10
	MaxPlanBoundaries   = MaxStrideBoundaries + 1 + MaxLadderBoundaries
)

func AffinityRung(tokens int) bool {
	strides := tokens / StrideTokens
	return tokens > 0 && tokens%StrideTokens == 0 && strides&(strides-1) == 0
}

// Anchors selects the deepest stride window, final boundary, and lower
// power-of-two rungs. Selection uses token counts, not list positions.
func Anchors(boundaries []protocol.PrefixCacheAnchor) []protocol.PrefixCacheAnchor {
	last := len(boundaries) - 1
	selected := make([]protocol.PrefixCacheAnchor, 0, min(len(boundaries), MaxPlanBoundaries))
	i, strides := last, 0
	for ; i >= 0 && strides < MaxStrideBoundaries; i-- {
		onStride := boundaries[i].TokenCount%StrideTokens == 0
		if onStride {
			strides++
		}
		if onStride || i == last {
			selected = append(selected, boundaries[i])
		}
	}
	for ; i >= 0; i-- {
		if AffinityRung(boundaries[i].TokenCount) {
			selected = append(selected, boundaries[i])
		}
	}
	slices.Reverse(selected)
	return selected
}
