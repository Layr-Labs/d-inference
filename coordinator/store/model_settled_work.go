package store

// ModelSettledWorkTotal is the realized, positive inference payout and paid
// workload recorded for one concrete model during a bounded settlement window.
// Base rewards are not work and never appear in these rows.
type ModelSettledWorkTotal struct {
	Model              string `json:"model"`
	WorkPayoutMicroUSD int64  `json:"work_payout_micro_usd"`
	PromptTokens       int64  `json:"prompt_tokens"`
	CompletionTokens   int64  `json:"completion_tokens"`
	Jobs               int64  `json:"jobs"`
}

// PaidTokens returns the total prompt plus completion tokens represented by the
// settled work rows.
func (t ModelSettledWorkTotal) PaidTokens() int64 {
	return t.PromptTokens + t.CompletionTokens
}
