package routingsim

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

// Outcome is the preflight classification of a single arrival. The values
// mirror the reason codes the consumer emits at the preflight admission gate.
type Outcome string

const (
	// OutcomeServed means a candidate provider exists and the best estimated
	// TTFT is within the deadline — the request would be dispatched.
	OutcomeServed Outcome = "served"
	// OutcomeMachineBusy means providers serve the model but all are at
	// capacity (candidateCount==0 && capacityRejections>0). Consumer reason
	// code: "machine_busy" (HTTP 429).
	OutcomeMachineBusy Outcome = "machine_busy"
	// OutcomeTTFTTooSlow means a candidate exists but even the fastest misses
	// the TTFT deadline. Consumer reason code: "ttft_too_slow" (HTTP 429).
	OutcomeTTFTTooSlow Outcome = "ttft_too_slow"
)

// TTFTDeadline replicates api.ttftDeadline locally: 5s base + 1ms per estimated
// prompt token. Replicated (not imported) so the harness has no dependency on
// the unexported api package and cannot drift silently — the calibration test
// would catch a formula change as a moved cliff.
func TTFTDeadline(promptTokens int) time.Duration {
	return 5*time.Second + time.Duration(promptTokens)*time.Millisecond
}

// ClassifyWithGate runs the REAL preflight capacity check for one arrival and
// maps it to an Outcome. softTTFT selects the gate policy:
//
//	candidateCount==0 && capacityRejections>0  -> machine_busy (both modes)
//	!softTTFT && bestTTFT over the deadline     -> ttft_too_slow (legacy hard gate)
//	softTTFT && a candidate exists              -> served (Routing v2 / PR #381:
//	                                               TTFT is a preference, not a reject)
//	otherwise                                   -> served
//
// modelTooLarge / no-provider cases collapse into the served default here; a
// well-formed fleet never produces them.
func ClassifyWithGate(reg *registry.Registry, a Arrival, softTTFT bool) Outcome {
	candidateCount, capacityRejections, _, bestTTFT, hasTTFT :=
		reg.QuickCapacityCheckWithTTFTForRequest(a.Model, a.PromptTokens, a.MaxTokens, registry.RequestTraits{}, false)

	if candidateCount == 0 && capacityRejections > 0 {
		return OutcomeMachineBusy
	}
	if !softTTFT && hasTTFT && bestTTFT > TTFTDeadline(a.PromptTokens) {
		return OutcomeTTFTTooSlow
	}
	return OutcomeServed
}

// Classify runs the legacy HARD TTFT gate (the calibration anchor): an arrival
// whose best estimated TTFT exceeds the deadline is rejected as ttft_too_slow.
func Classify(reg *registry.Registry, a Arrival) Outcome {
	return ClassifyWithGate(reg, a, false)
}

// Result is the per-arrival simulation record.
type Result struct {
	Arrival Arrival
	Outcome Outcome
}

// RunWithGate replays a whole trace through the preflight against reg with the
// given TTFT gate policy and returns the per-arrival results in trace order.
func RunWithGate(reg *registry.Registry, trace []Arrival, softTTFT bool) []Result {
	results := make([]Result, 0, len(trace))
	for _, a := range trace {
		results = append(results, Result{Arrival: a, Outcome: ClassifyWithGate(reg, a, softTTFT)})
	}
	return results
}

// Run replays a whole trace through the legacy HARD TTFT gate.
func Run(reg *registry.Registry, trace []Arrival) []Result {
	return RunWithGate(reg, trace, false)
}
