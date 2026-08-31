package api

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func schedulerPriorityLabel(priority store.VerificationPriority) string {
	switch priority {
	case store.VerificationPriorityFirstOrExpired:
		return "first_or_expired"
	case store.VerificationPriorityRecovery:
		return "recovery"
	default:
		return "refresh"
	}
}

func schedulerRetryStageLabel(stage int) string {
	if stage <= 1 {
		return "first"
	}
	if stage == 2 {
		return "second"
	}
	return "steady"
}

func (s *mdmVerificationScheduler) metricCounter(name, labelName, labelValue string) {
	if s.server.metrics != nil {
		s.server.metrics.IncCounter(name, MetricLabel{labelName, labelValue})
	}
	ddName := map[string]string{
		"mdm_scheduler_enqueued_total":       "mdm.scheduler.enqueued",
		"mdm_scheduler_deduplicated_total":   "mdm.scheduler.deduplicated",
		"mdm_scheduler_cancelled_total":      "mdm.scheduler.cancelled",
		"mdm_scheduler_queue_rejected_total": "mdm.scheduler.queue_rejected",
		"mdm_scheduler_grants_total":         "mdm.scheduler.grants",
		"mda_verification_total":             "mda.verification",
	}[name]
	if ddName == "" {
		ddName = name
	}
	s.server.ddIncr(ddName, []string{labelName + ":" + labelValue})
}

func (s *mdmVerificationScheduler) observeAttempt(work mdmSchedulerWork, result mdmSchedulerAttemptResult, duration time.Duration) {
	kind := string(work.job.Kind)
	outcome := string(result.outcome)
	queueWait := s.deps.now().Sub(work.enqueuedAt)
	if queueWait < 0 {
		queueWait = 0
	}
	if s.server.metrics != nil {
		s.server.metrics.IncCounter("mdm_scheduler_attempts_total", MetricLabel{"kind", kind}, MetricLabel{"outcome", outcome})
		s.server.metrics.ObserveHistogram("mdm_scheduler_attempt_seconds", duration.Seconds(), MetricLabel{"kind", kind}, MetricLabel{"outcome", outcome})
		s.server.metrics.ObserveHistogram("mdm_scheduler_queue_wait_seconds", queueWait.Seconds(), MetricLabel{"kind", kind}, MetricLabel{"priority", schedulerPriorityLabel(work.job.Priority)})
		if result.outcome == store.VerificationOutcomeTimeout {
			s.server.metrics.IncCounter("mdm_scheduler_timeouts_total", MetricLabel{"kind", kind})
		}
	}
	s.server.ddIncr("mdm.scheduler.attempts", []string{"kind:" + kind, "outcome:" + outcome})
	s.server.ddHistogram("mdm.scheduler.attempt_seconds", duration.Seconds(), []string{"kind:" + kind, "outcome:" + outcome})
	s.server.ddHistogram("mdm.scheduler.queue_wait_seconds", queueWait.Seconds(),
		[]string{"kind:" + kind, "priority:" + schedulerPriorityLabel(work.job.Priority)})
	if result.outcome == store.VerificationOutcomeTimeout {
		s.server.ddIncr("mdm.scheduler.timeouts", []string{"kind:" + kind})
	}
	if result.granted && work.job.Kind == store.VerificationTaskSecurityInfo {
		s.metricCounter("mdm_scheduler_grants_total", "path", "live")
	}
	if work.job.Kind == store.VerificationTaskMDA {
		mdaOutcome := outcome
		if result.outcome == store.VerificationOutcomeSuccess {
			mdaOutcome = "verified"
		}
		s.metricCounter("mda_verification_total", "outcome", mdaOutcome)
	}
}

func (s *mdmVerificationScheduler) publishDogStatsDGauges() {
	type gauge struct {
		name  string
		value float64
		tags  []string
	}
	values := make([]gauge, 0, 8)
	s.mu.Lock()
	for _, kind := range []store.VerificationTaskKind{
		store.VerificationTaskSecurityInfo, store.VerificationTaskMDA,
	} {
		values = append(values, gauge{
			name:  "mdm.scheduler.active_attempts",
			value: float64(s.active[kind]),
			tags:  []string{"kind:" + string(kind)},
		})
		for _, priority := range []store.VerificationPriority{
			store.VerificationPriorityFirstOrExpired,
			store.VerificationPriorityRecovery,
			store.VerificationPriorityRefresh,
		} {
			count := 0
			for _, job := range s.jobs {
				if !job.running && job.record.Kind == kind &&
					job.record.Priority == priority {
					count++
				}
			}
			values = append(values, gauge{
				name: "mdm.scheduler.queue_depth", value: float64(count),
				tags: []string{
					"kind:" + string(kind),
					"priority:" + schedulerPriorityLabel(priority),
				},
			})
		}
	}
	s.mu.Unlock()
	for _, value := range values {
		s.server.ddGauge(value.name, value.value, value.tags)
	}
}

func (s *mdmVerificationScheduler) registerMetrics() {
	if s.server.metrics == nil {
		return
	}
	for _, kind := range []store.VerificationTaskKind{store.VerificationTaskSecurityInfo, store.VerificationTaskMDA} {
		kind := kind
		s.server.metrics.RegisterGaugeLabels("mdm_scheduler_active_attempts", func() float64 {
			s.mu.Lock()
			defer s.mu.Unlock()
			return float64(s.active[kind])
		}, MetricLabel{"kind", string(kind)})
		for _, priority := range []store.VerificationPriority{store.VerificationPriorityFirstOrExpired, store.VerificationPriorityRecovery, store.VerificationPriorityRefresh} {
			priority := priority
			s.server.metrics.RegisterGaugeLabels("mdm_scheduler_queue_depth", func() float64 {
				s.mu.Lock()
				defer s.mu.Unlock()
				count := 0
				for _, job := range s.jobs {
					if !job.running && job.record.Kind == kind && job.record.Priority == priority {
						count++
					}
				}
				return float64(count)
			}, MetricLabel{"kind", string(kind)}, MetricLabel{"priority", schedulerPriorityLabel(priority)})
		}
	}
}
