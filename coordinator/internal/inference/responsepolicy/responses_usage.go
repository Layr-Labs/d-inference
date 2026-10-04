package responsepolicy

import (
	"github.com/eigeninference/d-inference/coordinator/api/types"
)

func BuildResponsesUsage(promptTokens, completionTokens, reasoningTokens, cachedTokens uint64) types.ResponsesUsage {
	return types.ResponsesUsage{
		InputTokens:        int(promptTokens),
		InputTokensDetail:  types.ResponsesUsageDetail{CachedTokens: int(cachedTokens)},
		OutputTokens:       int(completionTokens),
		OutputTokensDetail: types.ResponsesUsageDetail{ReasoningTokens: int(reasoningTokens)},
		TotalTokens:        int(promptTokens) + int(completionTokens),
	}
}
