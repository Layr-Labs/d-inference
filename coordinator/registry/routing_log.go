package registry

// logRoutingDecision emits a structured debug-level record of the
// winning candidate and its cost breakdown. Cheap when the level is
// disabled, since slog short-circuits before formatting.
func (r *Registry) logRoutingDecision(model string, pr *PendingRequest, winner *routingCandidate, candidates int) {
	if r.logger == nil || winner == nil {
		return
	}
	bd := winner.breakdown
	r.logger.Debug("routing_decision",
		"request_id", pr.RequestID,
		"model", model,
		"winner", winner.provider.ID,
		"cost_ms", bd.Total,
		"state_ms", bd.StateMs,
		"queue_ms", bd.QueueMs,
		"pending_ms", bd.PendingMs,
		"backlog_ms", bd.BacklogMs,
		"this_req_ms", bd.ThisReqMs,
		"health_ms", bd.HealthMs,
		"effective_tps", winner.effectiveTPS,
		"effective_queue", winner.effectiveQueue,
		"candidates", candidates,
	)
}
