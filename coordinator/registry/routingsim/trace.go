package routingsim

// Arrival is a single request in a replay trace. It carries only the fields the
// preflight admission path consumes: the model, the estimated prompt-token
// count, and the requested max output tokens.
type Arrival struct {
	Model        string
	PromptTokens int
	MaxTokens    int
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
