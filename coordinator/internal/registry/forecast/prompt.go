package forecast

import "github.com/eigeninference/d-inference/coordinator/protocol"

// PromptCounts selects candidate-qualified work without changing request
// accounting. Cache authentication and generation checks belong to the caller.
func PromptCounts(estimated, firstContent int, work *protocol.PromptWork, artifact, contract string, authenticatedCacheTokens int, cacheQualified bool) (int, int) {
	prompt := max(0, estimated)
	upper := max(prompt, firstContent)
	if work != nil && work.IsQualifiedFor(artifact, contract) {
		prompt, upper = work.PromptTokens, work.UpperBoundTokens
	}
	if cacheQualified {
		prompt, upper = authenticatedCacheTokens, authenticatedCacheTokens
	}
	return prompt, upper
}
