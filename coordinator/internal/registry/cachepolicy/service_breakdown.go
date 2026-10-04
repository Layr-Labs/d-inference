package cachepolicy

// ServiceBreakdown decomposes routing cost for pricing, decisions and logging.
// It is a detached value: total equals costMs modulo floating-point rounding.
type ServiceBreakdown struct {
	StateMs   float64
	QueueMs   float64
	PendingMs float64
	BacklogMs float64
	ThisReqMs float64
	HealthMs  float64
	// CapacityRateMs is the gray-box capacity-503 rate penalty
	// (capacity_rate.go): rate times EIGENINFERENCE_CAPACITY_RATE_PENALTY_MS once
	// the pair's windowed reject rate clears the threshold with a minimum
	// sample. 0 for healthy pairs, so the cost is byte-for-byte unchanged.
	CapacityRateMs float64
	TTFTMs         float64 // calibrated TTFT estimate for this candidate (gate/ceiling input)
	// RawTTFTMs is the pre-calibration ttftMsFromSnapshot value. The calibrator
	// learns against it so the feedback loop converges on the absolute
	// actual/predicted ratio instead of compounding.
	RawTTFTMs float64
	// CacheDiscountMs is subtracted only after every normal eligibility and
	// admission gate has passed. It never reduces reservations or token budgets.
	CacheDiscountMs float64
	Total           float64
}
