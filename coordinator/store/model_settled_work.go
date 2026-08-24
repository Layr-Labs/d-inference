package store

// ModelSettledWorkTotal is the realized, positive inference payout and paid
// workload recorded for one consumer-requested market identity during a bounded
// settlement window. PublicModel is empty for legacy rows whose requested
// identity was not persisted; callers must leave those rows unattributed.
// Base rewards are not work and never appear in these rows.
type ModelSettledWorkTotal struct {
	PublicModel        string `json:"public_model"`
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
