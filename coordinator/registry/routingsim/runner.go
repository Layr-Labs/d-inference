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

// Classify runs the REAL consumer preflight admission for one arrival and maps
// it to an Outcome exactly as coordinator/api/consumer.go does at the preflight:
//
//	candidateCount==0 && capacityRejections>0  -> machine_busy
//	bestTTFT over the deadline                 -> ttft_too_slow
//	otherwise                                  -> served
//
// modelTooLarge / no-provider cases collapse into the served default here
// because, like the task's classification, the harness focuses on the
// capacity-vs-TTFT distinction; a well-formed fleet never produces them.
func Classify(reg *registry.Registry, a Arrival) Outcome {
	candidateCount, capacityRejections, _, bestTTFT, hasTTFT :=
		reg.QuickCapacityCheckWithTTFTForRequest(a.Model, a.PromptTokens, a.MaxTokens, registry.RequestTraits{}, false)

	if candidateCount == 0 && capacityRejections > 0 {
		return OutcomeMachineBusy
	}
	if hasTTFT && bestTTFT > TTFTDeadline(a.PromptTokens) {
		return OutcomeTTFTTooSlow
	}
	return OutcomeServed
}

// Result is the per-arrival simulation record.
type Result struct {
	Arrival Arrival
	Outcome Outcome
}

// Run replays a whole trace through the preflight against reg and returns the
// per-arrival results in trace order.
func Run(reg *registry.Registry, trace []Arrival) []Result {
	results := make([]Result, 0, len(trace))
	for _, a := range trace {
		results = append(results, Result{Arrival: a, Outcome: Classify(reg, a)})
	}
	return results
}
