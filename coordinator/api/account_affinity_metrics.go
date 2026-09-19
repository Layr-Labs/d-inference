package api

import (
	"math"
	"strconv"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

// Account affinity is measured independently of prefix-cache opportunities:
// choosing an account's preferred machine is not evidence of a cache hit.
// Both sinks receive only closed-vocabulary labels and numerical observations.
func (s *Server) emitAccountAffinityMetrics(observation registry.AccountAffinityObservation) {
	if s == nil || !observation.Evaluated {
		return
	}
	mode := accountAffinityMetricMode(observation.Mode)
	labels := []MetricLabel{
		{"mode", mode},
		{"reason", accountAffinityMetricReason(observation.Reason)},
		{"applied", strconv.FormatBool(observation.Applied)},
		{"would_change", strconv.FormatBool(observation.WouldChange)},
	}
	tags := make([]string, len(labels))
	for index, label := range labels {
		tags[index] = label.Name + ":" + label.Value
	}
	s.ddIncr("routing.account_affinity", tags)
	if s.metrics != nil {
		s.metrics.IncCounter("routing.account_affinity", labels...)
	}
	observe := func(name string, value float64) {
		if value < 0 || math.IsNaN(value) || math.IsInf(value, 0) {
			return
		}
		s.ddHistogram(name, value, []string{"mode:" + mode})
		if s.metrics != nil {
			s.metrics.ObserveHistogram(name, value, MetricLabel{"mode", mode})
		}
	}
	observe("routing.account_affinity.candidates", float64(observation.CandidateCount))
	// Zero rank denotes fallback, not an idle affinity choice. AddedTTFTMs is
	// load-induced delay relative to this machine's estimated idle self, never
	// the latency difference from another provider.
	if observation.Rank > 0 && observation.Rank <= observation.CandidateCount {
		observe("routing.account_affinity.rank", float64(observation.Rank))
		observe("routing.account_affinity.added_ttft_ms", observation.AddedTTFTMs)
	}
}

func accountAffinityMetricMode(mode string) string {
	switch mode {
	case "off", "shadow", "on":
		return mode
	default:
		return "unknown"
	}
}

func accountAffinityMetricReason(reason string) string {
	switch reason {
	case "off", "invalid_config", "missing_account", "missing_model", "vision",
		"no_candidates", "no_known_ttft", "no_identity", "no_eligible_candidate",
		"preferred", "spill", "plan_fallback":
		return reason
	default:
		return "unknown"
	}
}
