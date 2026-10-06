package registry

// Heartbeat-triggered queue-drain suppression.
//
// Every heartbeat from a provider re-runs the queue drain for the models it
// serves (Registry.Heartbeat). Fleet-wide that is ~260 passes/s, and under
// saturation each pass costs a full fleet scan (~1 ms / 2 MB at 1,300
// providers) only to re-derive "no candidate". Heartbeats almost never free
// capacity themselves — completions, cancels, failed attempts (SetProviderIdle),
// challenge recoveries (RecordChallengeSuccess), disconnects, and load_model
// completions (DrainQueuedRequestsForModel) do, and those triggers are never
// suppressed. So a heartbeat skips a model whose last drain pass ended in a
// pure capacity/TTFT rejection less than queuedrain.SuppressionWindow ago.

// drainQueuedRequestsForHeartbeat is the heartbeat-triggered drain: identical
// to drainQueuedRequestsForModelsWithReason(models, DrainTriggerHeartbeat)
// except that models whose queue was found saturated within
// queuedrain.SuppressionWindow are skipped. Capacity-freeing triggers must
// keep calling drainQueuedRequestsForModelsWithReason directly.
func (r *Registry) drainQueuedRequestsForHeartbeat(models []string) {
	if len(models) == 0 {
		return
	}
	kept := r.drainSuppress.Unsuppressed(models)
	if len(kept) != len(models) {
		r.armTrailingDrains(models, kept)
	}
	r.drainQueuedRequestsForModelsWithReason(kept, DrainTriggerHeartbeat)
}

// armTrailingDrains schedules one end-of-window drain for every model the
// heartbeat was suppressed on (those in models but not in kept) that does not
// already have one armed. The trailing pass goes through
// drainQueuedRequestsForModelsWithReason directly (never suppressed), still
// attributed to the heartbeat trigger that armed it, and clears its own mark
// first, so a heartbeat arriving after it runs can arm the next one.
func (r *Registry) armTrailingDrains(models, kept []string) {
	r.drainSuppress.Arm(models, kept, func(model string) {
		r.drainQueuedRequestsForModelsWithReason([]string{model}, DrainTriggerHeartbeat)
	})
}
