package autopilot

import (
	"fmt"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/residency"
)

// Cohorts are bounded, prompt-free capability and work-size bins. The model
// remains an exact catalog build; a cohort key is never sent to a provider.
func ModelID(key string) string { return residency.ModelID(key) }
func ShapeKey(s DemandSample) string {
	input, output := 0, 0
	for input < len(autopilotPromptBounds)-1 && s.PromptTokens > autopilotPromptBounds[input] {
		input++
	}
	for output < 3 && s.RequestedMaxTokens > []int{256, 2048, 8192}[output] {
		output++
	}
	deadline := -1
	if s.DeadlineKnown {
		deadline = 0
		if s.FirstContentDeadline > 0 {
			deadline = 1
			for deadline <= 5 && s.FirstContentDeadline.Seconds() > []float64{5, 15, 30, 60, 120}[deadline-1] {
				deadline++
			}
		}
	}
	return fmt.Sprintf("%s\x1f%s:%d:%d:%d", s.Model, s.Requirements.cohortKey(), input, output, deadline)
}

func (d *DemandTracker) ShapeSnapshot(now time.Time, window time.Duration) map[string]DemandView {
	d.mu.Lock()
	defer d.mu.Unlock()
	out := map[string]DemandView{}
	for key, tracker := range d.shapes {
		samples := tracker.Snapshot(now, window)
		if sample, ok := samples[ModelID(key)]; ok && sample.Requests > 0 {
			out[key] = sample
		} else {
			delete(d.shapes, key)
		}
	}
	return out
}

func demandForModel(demand map[string]DemandView, model string) DemandView {
	var out DemandView
	for key, d := range demand {
		if ModelID(key) != model {
			continue
		}
		out.Rate += d.Rate
		out.Requests += d.Requests
		out.CapacityShed += d.CapacityShed
		if d.LastDemand.After(out.LastDemand) {
			out.LastDemand = d.LastDemand
		}
	}
	return out
}

func hasDemandForModel(demand map[string]DemandView, model string) bool {
	for key := range demand {
		if ModelID(key) == model {
			return true
		}
	}
	return false
}

func ShapeLabel(key string) string { _, shape, _ := strings.Cut(key, "\x1f"); return shape }
