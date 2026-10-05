package shared

import (
	"sort"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func EmptyModelDemandSeries(since, until time.Time, width time.Duration) []store.ModelDemandBucket {
	out := []store.ModelDemandBucket{}
	for at := since; at.Before(until); at = at.Add(width) {
		out = append(out, store.ModelDemandBucket{Timestamp: at})
	}
	return out
}

func validDemandOutcome(v string) bool {
	switch v {
	case "completed", "latency_rejected", "capacity_rejected", "timed_out", "failed", "cancelled", "unknown", "excluded":
		return true
	}
	return false
}

// Summaries never include private residuals from suppressed hours.
func SummarizeModelDemand(out *store.ModelDemandSnapshot) {
	for i := range out.Models {
		model := &out.Models[i]
		for j := range model.TimeSeries {
			if counts := model.TimeSeries[j].Counts; counts != nil {
				model.Merge(counts)
			}
		}
	}
	sort.Slice(out.Models, func(i, j int) bool {
		if out.Models[i].Requests != out.Models[j].Requests {
			return out.Models[i].Requests > out.Models[j].Requests
		}
		return out.Models[i].Model < out.Models[j].Model
	})
}
