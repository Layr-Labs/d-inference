// Package ttftforecast owns historical TTFT diagnostics, not admission confidence.
package ttftforecast

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/modelpolicy"
)

const DefaultDeadlineBaseMS = 10000.0

// Work combines heartbeat occupancy and locally reserved prompt work. Locally
// known prompts replace the proxy only when the heartbeat reflects no work.
type Work struct {
	Running, Waiting, Pending int
	PrefillKnown              bool
	PrefillTokens             float64
	PrefillUnknown            int
}

func (w Work) Occupancy() int {
	return max(0, w.Pending, w.Running+w.Waiting)
}

func (w Work) QueuedPrefill(prompt int) float64 {
	if prompt < 0 {
		prompt = 0
	}
	waiting := w.Waiting
	reflected := w.Running + w.Waiting
	if reflected == 0 && w.PrefillKnown {
		return w.PrefillTokens + float64(w.PrefillUnknown)*float64(prompt)
	}
	if extra := w.Pending - reflected; extra > 0 {
		waiting += extra
	}
	if waiting <= 0 {
		return 0
	}
	return float64(waiting) * float64(prompt)
}

type Estimate struct {
	HasCapacity                         bool
	StatePenalty, PrefillTPS, DecodeTPS float64
	Work                                Work
}

// Base excludes the occupancy delay regardless of shadow configuration.
func (e Estimate) Base(prompt int) float64 {
	if !e.HasCapacity {
		return 0
	}
	if prompt < 0 {
		prompt = 0
	}
	prefill, decode := e.PrefillTPS, e.DecodeTPS
	if prefill <= 0 {
		prefill = 1
	}
	if decode <= 0 {
		decode = 1
	}
	queuedMS := e.Work.QueuedPrefill(prompt) / prefill * 1000
	thisMS := float64(prompt) / prefill * 1000
	return e.StatePenalty + queuedMS + thisMS + 1000/decode
}

func OccupancyDelay(alpha float64, occupancy int, projectedDecodeTPS float64) float64 {
	if alpha <= 0 || occupancy <= 0 {
		return 0
	}
	if projectedDecodeTPS <= 0 {
		projectedDecodeTPS = 1
	}
	return alpha * float64(occupancy) * 1000 / projectedDecodeTPS
}

func Shadow(base, occupancyDelay float64) float64 {
	if base <= 0 {
		return base
	}
	return base + occupancyDelay
}

func Deadline(model string, prompt int, baseMS float64) float64 {
	base := time.Duration(baseMS * float64(time.Millisecond))
	return float64(modelpolicy.UpstreamFirstContentDeadline(model, prompt, base)) / float64(time.Millisecond)
}
