// Package utilization computes fleet utilization from detached capacity and
// warm-pool observations.
package utilization

import "time"

// ModelCapacity is the per-model capacity observation needed for utilization.
type ModelCapacity struct {
	ModelID              string
	WarmProviders        int
	RunningProviders     int
	ColdProviders        int
	ActiveRequests       int
	QueuedRequests       int
	AggregateTPS         float64
	TokenBudgetTotal     int64
	TokenBudgetRemaining int64
}

// WarmPoolSnapshot is the controller's demand and serving-capacity observation.
type WarmPoolSnapshot struct {
	Model              string
	WarmProviders      int
	QualityConcurrency int
	DemandConcurrency  float64
	TargetWarm         int
	SpillArrivalRate   float64
}

// ModelUtilization is the per-model utilization breakdown across both axes.
type ModelUtilization struct {
	Model string `json:"model"`

	// Headline for this model: the bottleneck across axes, clamped to [0,1].
	Utilization float64 `json:"utilization"`

	// Warm serving-capacity axis (Little's Law).
	WarmUtilization    float64 `json:"warm_utilization"` // demand / serving_capacity (uncapped)
	DemandConcurrency  float64 `json:"demand_concurrency"`
	ServingCapacity    float64 `json:"serving_capacity"`
	WarmProviders      int     `json:"warm_providers"`
	TargetWarm         int     `json:"target_warm"`
	QualityConcurrency int     `json:"quality_concurrency"`
	SpillArrivalRate   float64 `json:"spill_arrival_rate"` // EWMA req/s currently shed at quality
	HasWarmData        bool    `json:"has_warm_data"`

	// Token-budget (KV-cache memory) axis.
	TokenBudgetUtilization float64 `json:"token_budget_utilization"`
	TokenBudgetUsed        int64   `json:"token_budget_used"`
	TokenBudgetTotal       int64   `json:"token_budget_total"`

	// Occupancy (informational).
	ActiveRequests   int     `json:"active_requests"`
	QueuedRequests   int     `json:"queued_requests"`
	RunningProviders int     `json:"running_providers"`
	ColdProviders    int     `json:"cold_providers"`
	AggregateTPS     float64 `json:"aggregate_tps"`
}

// NetworkUtilization is the fleet-wide utilization summary.
type NetworkUtilization struct {
	// Utilization is the public headline: capacity-weighted aggregate of the
	// binding axis, clamped to [0,1] (1.0 = fully saturated).
	Utilization float64 `json:"utilization"`

	// Raw aggregates (uncapped) for drill-down.
	WarmUtilization        float64 `json:"warm_utilization"`         // Σdemand / Σserving_capacity
	TokenBudgetUtilization float64 `json:"token_budget_utilization"` // Σused / Σtotal
	BottleneckUtilization  float64 `json:"bottleneck_utilization"`   // max per-model utilization
	BottleneckModel        string  `json:"bottleneck_model,omitempty"`

	DemandConcurrency float64 `json:"demand_concurrency"` // Σ L across models
	ServingCapacity   float64 `json:"serving_capacity"`   // Σ warm×quality across models
	CapacityTPS       float64 `json:"capacity_tps"`       // Σ aggregate decode TPS
	SpillArrivalRate  float64 `json:"spill_arrival_rate"` // Σ req/s shed at quality
	ActiveRequests    int     `json:"active_requests"`
	QueuedRequests    int     `json:"queued_requests"`

	Models          []ModelUtilization `json:"models"`
	GeneratedAt     time.Time          `json:"generated_at"`
	WarmDataAgeSecs float64            `json:"warm_data_age_seconds"` // staleness of warm-pool snapshot (0 = none)
	HasWarmPoolData bool               `json:"has_warm_pool_data"`
}

// PublicNetworkUtilization is the privacy-safe projection served on the
// unauthenticated /v1/stats endpoint. It carries the headline utilization, the
// two axis ratios, the bottleneck, and the already-public aggregate occupancy —
// but deliberately omits the warm-pool control-loop internals (absolute demand /
// serving concurrency, spill arrival rate, target warm, quality concurrency, and
// the per-model breakdown), which stay admin-only via /v1/admin/utilization.
type PublicNetworkUtilization struct {
	Utilization            float64 `json:"utilization"`
	WarmUtilization        float64 `json:"warm_utilization"`
	TokenBudgetUtilization float64 `json:"token_budget_utilization"`
	BottleneckUtilization  float64 `json:"bottleneck_utilization"`
	BottleneckModel        string  `json:"bottleneck_model,omitempty"`
	CapacityTPS            float64 `json:"capacity_tps"`
	ActiveRequests         int     `json:"active_requests"`
	QueuedRequests         int     `json:"queued_requests"`
}

// Public returns the privacy-safe projection of the full snapshot for the public
// stats endpoint.
func (n NetworkUtilization) Public() PublicNetworkUtilization {
	return PublicNetworkUtilization{
		Utilization:            n.Utilization,
		WarmUtilization:        n.WarmUtilization,
		TokenBudgetUtilization: n.TokenBudgetUtilization,
		BottleneckUtilization:  n.BottleneckUtilization,
		BottleneckModel:        n.BottleneckModel,
		CapacityTPS:            n.CapacityTPS,
		ActiveRequests:         n.ActiveRequests,
		QueuedRequests:         n.QueuedRequests,
	}
}

// FleetCapacity is the provider-deduped aggregate throughput and KV/token budget
// of the routable public fleet. It is computed by counting each provider once,
// which avoids the multi-model double-counting that arises from summing
// per-model ModelCapacity rows (a provider advertising N models appears in N
// rows, and slots on one machine draw on a single memory pool).
type FleetCapacity struct {
	DecodeTPS  float64 // Σ per-provider rated decode tok/s (counted once)
	BudgetUsed int64   // Σ per-provider committed (used+queued) token budget across slots
	// BudgetTotal is Σ per-provider pooled token budget: each slot reports a
	// private re-sliced grant, and grants add. A live request may transiently
	// leave BudgetUsed > BudgetTotal after a grant shrink.
	BudgetTotal int64
}
