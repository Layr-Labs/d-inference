package admission

// PendingTokenBudget preserves physical prompt and output commitments even when
// cache reuse or first-content delivery reduces predicted prefill work.
func PendingTokenBudget(prompt, maxTokens, defaultMaxTokens int) int {
	if prompt < 0 {
		prompt = 0
	}
	if maxTokens <= 0 {
		maxTokens = defaultMaxTokens
	}
	return prompt + maxTokens
}
