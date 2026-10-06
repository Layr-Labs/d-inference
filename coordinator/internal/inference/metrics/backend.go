package metrics

import (
	"math"

	"github.com/eigeninference/d-inference/coordinator/internal/inference/backend"
)

const (
	RequestTTFT      = "inference.ttft_ms"
	RequestDecodeTPS = "inference.decode_tps"
)

func UsableSample(v float64) bool {
	return v > 0 && !math.IsNaN(v) && !math.IsInf(v, 0)
}

func (r Reporter) BackendOutcome(model string, attr backend.Attribution, class string) {
	if model == "" {
		model = "unknown"
	}
	if r.Observation == nil || r.Observation.Datadog() == nil {
		return
	}
	tags := attr.AppendTags(append(make([]string, 0, 4), "model:"+model, "class:"+class))
	r.Observation.Incr(RequestOutcomeMetric, tags)
}

// BackendLatency uses the same completed-route measurements as persisted TTFT
// and decode throughput. Unmeasurable values must not become zero samples.
func (r Reporter) BackendLatency(model string, attr backend.Attribution, ttftMs, decodeTPS float64) {
	if r.Observation == nil || r.Observation.Datadog() == nil {
		return
	}
	ttftUsable, decodeUsable := UsableSample(ttftMs), UsableSample(decodeTPS)
	if !ttftUsable && !decodeUsable {
		return
	}
	tags := attr.AppendTags(append(make([]string, 0, 3), "model:"+model))
	if ttftUsable {
		r.Observation.Histogram(RequestTTFT, ttftMs, tags)
	}
	if decodeUsable {
		r.Observation.Histogram(RequestDecodeTPS, decodeTPS, tags)
	}
}
