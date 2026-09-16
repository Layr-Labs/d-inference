package metrics

// MDMSchedulerMetrics is the queue that drives MicroMDM SecurityInfo and Apple
// device-attestation verification: what was enqueued, what was collapsed into an
// in-flight job, what was refused, and how long an attempt took. Trust is
// granted off the back of these jobs, so a queue that stops draining shows up
// here before it shows up as a fleet with no hardware trust.
//
// Every counter here has an in-process mirror under its `_total` name, because
// this subsystem is what GET /v1/admin/metrics was extended for. Before the
// catalog the pairing lived in a name-translation map inside the scheduler
// (metricCounter), which is the shape this package exists to replace: the map
// was the only record that two names were one series, and nothing checked it.
type MDMSchedulerMetrics struct {
	// Enqueued is a job accepted onto the queue, by why it was created.
	Enqueued *Counter
	// Deduplicated is an enqueue collapsed into an existing job, tagged by the
	// state that job was in. A high dedup rate is healthy — it means retries are
	// not multiplying work.
	Deduplicated *Counter
	// Cancelled is a queued job dropped before it ran (the provider went away, or
	// a fast path already granted trust).
	Cancelled *Counter
	// QueueRejected is an enqueue refused because the queue was full, by the
	// priority that lost. Refresh work being rejected is expected under load;
	// first_or_expired being rejected is capacity loss.
	QueueRejected *Counter
	// Grants is hardware trust granted, by which path produced it: `live` (a
	// SecurityInfo attempt), `late` (a SecurityInfo that arrived after the
	// decision window), or `reuse` (a prior verification still valid).
	Grants *Counter

	// Attempts is one verification attempt that finished, by task kind and
	// outcome.
	Attempts *Counter
	// Timeouts is the subset of attempts that timed out, kept separately because
	// it is the series an alert is built on.
	Timeouts *Counter
	// AttemptSeconds is how long an attempt took, by kind and outcome.
	AttemptSeconds *Distribution
	// QueueWaitSeconds is how long a job waited before running, by kind and the
	// priority it was queued at. This is the latency that matters to a provider
	// waiting for trust.
	QueueWaitSeconds *Distribution
	// RetryDelaySeconds is the backoff applied after a failed attempt, by retry
	// stage (`first`, `second`, `steady`) rather than exact attempt number.
	RetryDelaySeconds *Distribution

	// ActiveAttempts and QueueDepth are the queue's shape right now, pushed on
	// the gauge loop. They have no mirror here: the in-process registry serves
	// the same two readings from registered gauge functions it evaluates on
	// scrape, which is a pull, and a pull cannot be expressed as a sample.
	ActiveAttempts *Gauge
	QueueDepth     *Gauge
}

func newMDMSchedulerMetrics(m *Metrics) *MDMSchedulerMetrics {
	return &MDMSchedulerMetrics{
		Enqueued: m.mirroredCounter("mdm.scheduler.enqueued", "mdm_scheduler_enqueued_total",
			"Verification jobs accepted onto the queue, by reason",
			"reason"),
		Deduplicated: m.mirroredCounter("mdm.scheduler.deduplicated", "mdm_scheduler_deduplicated_total",
			"Enqueues collapsed into an in-flight job, by that job's state",
			"state"),
		Cancelled: m.mirroredCounter("mdm.scheduler.cancelled", "mdm_scheduler_cancelled_total",
			"Queued jobs dropped before running, by reason",
			"reason"),
		QueueRejected: m.mirroredCounter("mdm.scheduler.queue_rejected", "mdm_scheduler_queue_rejected_total",
			"Enqueues refused because the queue was full, by the priority that lost",
			"priority"),
		Grants: m.mirroredCounter("mdm.scheduler.grants", "mdm_scheduler_grants_total",
			"Hardware trust granted, by path (live, late, reuse)",
			"path"),

		Attempts: m.mirroredCounter("mdm.scheduler.attempts", "mdm_scheduler_attempts_total",
			"Verification attempts that finished, by task kind and outcome",
			"kind", "outcome"),
		Timeouts: m.mirroredCounter("mdm.scheduler.timeouts", "mdm_scheduler_timeouts_total",
			"Verification attempts that timed out, by task kind",
			"kind"),
		AttemptSeconds: m.mirroredDistribution("mdm.scheduler.attempt_seconds", "mdm_scheduler_attempt_seconds",
			"Verification attempt duration in seconds, by kind and outcome",
			"kind", "outcome"),
		QueueWaitSeconds: m.mirroredDistribution("mdm.scheduler.queue_wait_seconds", "mdm_scheduler_queue_wait_seconds",
			"Time a job waited before running, in seconds, by kind and queued priority",
			"kind", "priority"),
		RetryDelaySeconds: m.mirroredDistribution("mdm.scheduler.retry_delay_seconds", "mdm_scheduler_retry_delay_seconds",
			"Backoff applied after a failed attempt, in seconds, by retry stage",
			"stage"),

		ActiveAttempts: m.gauge("mdm.scheduler.active_attempts",
			"Verification attempts running right now, by task kind",
			"kind"),
		QueueDepth: m.gauge("mdm.scheduler.queue_depth",
			"Queued jobs not yet running, by task kind and priority",
			"kind", "priority"),
	}
}
