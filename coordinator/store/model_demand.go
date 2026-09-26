package store

import (
	"context"
	"sort"
	"time"
)

const ModelDemandRetention = 31 * 24 * time.Hour

// Both privacy floors apply per model and UTC clock hour, for every window.
const ModelDemandMinRequests = 20
const ModelDemandMinConsumers = 3

// PublicDemandScope is private ledger metadata. Only explicitly scoped new
// traffic is eligible; historical records are never inferred to be public.
// ConsumerHash is used only for aggregation privacy, never returned publicly.
type PublicDemandScope struct {
	Model        string `json:"model"`
	ConsumerHash string `json:"consumer_hash"`
	Outcome      string `json:"outcome"`
}

// DemandOutcomeCounts partitions recorded arrivals into exactly one outcome.
// HTTP429 overlaps these outcomes and is diagnostic, not another partition.
type DemandOutcomeCounts struct {
	Requests         int64 `json:"requests"`
	Completed        int64 `json:"completed"`
	CapacityRejected int64 `json:"capacity_rejected"`
	LatencyRejected  int64 `json:"latency_rejected"`
	TimedOut         int64 `json:"timed_out"`
	Failed           int64 `json:"failed"`
	Cancelled        int64 `json:"cancelled"`
	Unknown          int64 `json:"unknown"`
	HTTP429          int64 `json:"http_429"`
}

// Missing bucket counts mean no eligible hourly cohorts, never zero-filled.
// Coarse buckets sum eligible UTC hours only, not all demand in the interval.
type ModelDemandBucket struct {
	Timestamp time.Time            `json:"timestamp"`
	Counts    *DemandOutcomeCounts `json:"counts"`
}

// ModelDemandCounts totals are exactly the sum of its published time series.
type ModelDemandCounts struct {
	Model string `json:"model"`
	DemandOutcomeCounts
	TimeSeries []ModelDemandBucket `json:"time_series"`
}

// ModelDemandBucketSize selects presentation width, never privacy eligibility.
func ModelDemandBucketSize(since, until time.Time) time.Duration {
	if until.Sub(since) >= 30*24*time.Hour {
		return 24 * time.Hour
	}
	if until.Sub(since) >= 7*24*time.Hour {
		return 6 * time.Hour
	}
	return time.Hour
}

func emptyModelDemandSeries(since, until time.Time, width time.Duration) []ModelDemandBucket {
	out := []ModelDemandBucket{}
	for at := since; at.Before(until); at = at.Add(width) {
		out = append(out, ModelDemandBucket{Timestamp: at})
	}
	return out
}

type ModelDemandSnapshot struct {
	BucketSeconds       int64               `json:"bucket_seconds"`
	CollectionStartedAt time.Time           `json:"collection_started_at"`
	Models              []ModelDemandCounts `json:"models"`
}

type ModelDemandStore interface {
	ModelDemand(context.Context, time.Time, time.Time) (ModelDemandSnapshot, error)
	PruneModelDemand(context.Context, time.Time, int) (int, error)
}

func validDemandOutcome(v string) bool {
	switch v {
	case "completed", "latency_rejected", "capacity_rejected", "timed_out", "failed", "cancelled", "unknown", "excluded":
		return true
	}
	return false
}

func (c *DemandOutcomeCounts) add(outcome string, status int) {
	c.Requests++
	if status == 429 {
		c.HTTP429++
	}
	switch outcome {
	case "completed":
		c.Completed++
	case "capacity_rejected":
		c.CapacityRejected++
	case "latency_rejected":
		c.LatencyRejected++
	case "timed_out":
		c.TimedOut++
	case "failed":
		c.Failed++
	case "cancelled":
		c.Cancelled++
	default:
		c.Unknown++
	}
}

func (c *DemandOutcomeCounts) merge(other *DemandOutcomeCounts) {
	c.Requests += other.Requests
	c.Completed += other.Completed
	c.CapacityRejected += other.CapacityRejected
	c.LatencyRejected += other.LatencyRejected
	c.TimedOut += other.TimedOut
	c.Failed += other.Failed
	c.Cancelled += other.Cancelled
	c.Unknown += other.Unknown
	c.HTTP429 += other.HTTP429
}

// Summaries never include private residuals from suppressed hours.
func summarizeModelDemand(out *ModelDemandSnapshot) {
	for i := range out.Models {
		model := &out.Models[i]
		for j := range model.TimeSeries {
			if counts := model.TimeSeries[j].Counts; counts != nil {
				model.merge(counts)
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
