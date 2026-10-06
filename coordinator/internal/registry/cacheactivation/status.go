package cacheactivation

// CacheRoutingActivationStatus is aggregate operational state only. It never
// contains the activation HMAC key, request identifiers, accounts, models,
// prompt material, or sampling buckets.
type CacheRoutingActivationStatus struct {
	Percent     float64 `json:"percent"`
	MaxPlanQPS  float64 `json:"max_plan_qps"`
	Evaluated   uint64  `json:"evaluated"`
	SampledIn   uint64  `json:"sampled_in"`
	SampledOut  uint64  `json:"sampled_out"`
	RateLimited uint64  `json:"rate_limited"`
	Admitted    uint64  `json:"admitted"`
	Planned     uint64  `json:"planned"`
	ColdOnly    uint64  `json:"cold_only"`
	PlanEmpty   uint64  `json:"plan_empty"`
	PlanFailed  uint64  `json:"plan_failed"`
	// FirstSight counts planned novel prompts that were prepared for their
	// own follow-up. It is a subset of Planned, not an outcome.
	FirstSight uint64 `json:"first_sight"`
}
