package routingsim

import "time"

// Arrival is a single request in a replay trace. The first three fields are
// what the preflight admission path consumes: the model, the estimated
// prompt-token count, and the requested max output tokens. Generated traces
// (GenerateTrace) set only those; traces loaded from a request_profiles export
// (LoadProfilesNDJSON) also carry the recorded arrival time, request traits
// and production outcome so a replay can be scored against what actually
// happened.
type Arrival struct {
	Model        string
	PromptTokens int
	MaxTokens    int

	// ArrivedAt is the coordinator's received_at for the request; zero for
	// generated traces.
	ArrivedAt time.Time
	// RequiresVision / HasTools are the request traits the router gated on.
	RequiresVision bool
	HasTools       bool
	// ChosenProviderID is the provider production dispatched the winning
	// attempt to ("" when unknown).
	ChosenProviderID string
	// ActualTTFTMs is the provider-side time-to-first-content proxy available
	// in the profile export: (first_content_us - write_done_us)/1000, i.e.
	// request-fully-written-to-the-provider to first content chunk decoded by
	// the coordinator. It includes transport, provider queueing and prefill
	// but not the coordinator's own pre-dispatch stages. 0 means unknown. The
	// exact client-facing actual_ttft_ms lives on inference_routes (joined in
	// the request_waterfall view), not in this export.
	ActualTTFTMs float64
	// CoordRequestID / Attempt identify the source row (coord_request_id,
	// attempt) for joining a replay result back to production records.
	CoordRequestID string
	Attempt        int
	// Served is true when the row this arrival came from was the winning
	// attempt; a fully-failed logical request is replayed as demand with
	// Served=false and no ActualTTFTMs.
	Served bool
}

// PromptRange is a half-open [Min,Max) prompt-token range that contributes
// Count arrivals to a generated trace.
type PromptRange struct {
	Min, Max, Count int
}

// GenerateTrace deterministically builds a trace: for each range it emits Count
// arrivals whose prompt sizes are spread evenly across [Min,Max), all for the
// given model with the given maxTokens. Determinism (no RNG) keeps the harness a
// stable regression anchor. Ranges with Count <= 0 or Max <= Min are skipped.
func GenerateTrace(model string, maxTokens int, ranges []PromptRange) []Arrival {
	total := 0
	for _, r := range ranges {
		if r.Count > 0 && r.Max > r.Min {
			total += r.Count
		}
	}
	trace := make([]Arrival, 0, total)
	for _, r := range ranges {
		if r.Count <= 0 || r.Max <= r.Min {
			continue
		}
		span := r.Max - r.Min
		for i := 0; i < r.Count; i++ {
			// Evenly spaced sample within [Min,Max); never reaches Max.
			prompt := r.Min + (i*span)/r.Count
			trace = append(trace, Arrival{
				Model:        model,
				PromptTokens: prompt,
				MaxTokens:    maxTokens,
			})
		}
	}
	return trace
}

// CalibrationPromptMix returns a prompt-size mix that populates every report
// bucket with the given number of samples per bucket. The smallest range starts
// at 64 tokens (a realistic floor: the preflight treats a prompt of <=0 as 500,
// which would distort the [0-500) bucket) and the largest range runs to 8000.
func CalibrationPromptMix(perBucket int) []PromptRange {
	return []PromptRange{
		{Min: 64, Max: 500, Count: perBucket},
		{Min: 500, Max: 750, Count: perBucket},
		{Min: 750, Max: 1000, Count: perBucket},
		{Min: 1000, Max: 2000, Count: perBucket},
		{Min: 2000, Max: 4000, Count: perBucket},
		{Min: 4000, Max: 8000, Count: perBucket},
	}
}
