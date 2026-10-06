package protocol

// DeadlineWork is a conservative envelope of existing engine/service owners.
// It includes pre-submit and retiring leases. Unknown ownership never becomes
// zero work; Known=false makes calibrated admission use its legacy fallback.
// Epoch joins this envelope to the slot's performance measurement lifetime.
type DeadlineWork struct {
	Version          int     `json:"version"`
	Epoch            string  `json:"epoch"`
	Known            bool    `json:"known"`
	PrefillTokens    int64   `json:"prefill_tokens"`
	DecodeTokens     int64   `json:"decode_tokens"`
	RequestCount     int     `json:"request_count"`
	ContextTokensMax int     `json:"context_tokens_max"`
	ServiceFraction  float64 `json:"service_fraction"`
}

func (w *DeadlineWork) Clone() *DeadlineWork {
	if w == nil {
		return nil
	}
	out := *w
	return &out
}
