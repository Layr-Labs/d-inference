package forecast

// Allows distinguishes advisory forecasts from attempts requiring fresh feasible
// evidence. Hedging must not consume an already occupied whole-Mac allowance.
func Allows(estimate Estimate, request Request, occupied bool) bool {
	if request.Hedge && occupied {
		return false
	}
	if request.RequireFreshFeasible || request.Hedge {
		return estimate.Status == Feasible
	}
	return request.MaxTTFTMS <= 0 || estimate.Status != PredictedLate
}
