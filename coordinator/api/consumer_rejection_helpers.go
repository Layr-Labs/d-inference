package api

import (
	"encoding/json"
	"time"
)

// ttftMsForRejection converts a pre-flight TTFT estimate to milliseconds for the
// rejection ledger, returning 0 when the pre-flight produced no estimate.
func ttftMsForRejection(bestTTFT time.Duration, hasTTFT bool) float64 {
	if !hasTTFT {
		return 0
	}
	return float64(bestTTFT.Milliseconds())
}

// rejectionSamplingParams captures only the non-content sampling knobs already
// parsed from an inbound request body for the rejection ledger. It never
// includes prompt/message/input content. Returns nil when none are present.
func rejectionSamplingParams(parsed map[string]any) json.RawMessage {
	if parsed == nil {
		return nil
	}
	knobs := make(map[string]any, 4)
	for _, k := range []string{"temperature", "top_p", "presence_penalty", "frequency_penalty"} {
		if v, ok := parsed[k]; ok {
			knobs[k] = v
		}
	}
	if len(knobs) == 0 {
		return nil
	}
	b, err := json.Marshal(knobs)
	if err != nil {
		return nil
	}
	return b
}
