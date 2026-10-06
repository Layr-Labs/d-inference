// Package longprompt prices the additional first-token blocking cost for long prompts.
package longprompt

const DefaultThresholdTokens = 0
const DefaultPrefillWeight = 2.0

// Penalty amplifies the full blocking time, including any cold-model load.
func Penalty(reqPromptTokens int, ttftBlockMs float64, thresholdTokens int, prefillWeight float64) float64 {
	if thresholdTokens <= 0 || reqPromptTokens < thresholdTokens {
		return 0
	}
	if ttftBlockMs <= 0 || prefillWeight <= 1.0 {
		return 0
	}
	return (prefillWeight - 1.0) * ttftBlockMs
}
