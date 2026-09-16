package mdmscheduler

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/telemetry/metrics"
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

func recordCounter(deps Dependencies, name, labelName, labelValue string) {
	if deps.Metrics() != nil {
		deps.Metrics().IncCounter(name, metrics.Label{Name: labelName, Value: labelValue})
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
	deps.Counter(ddName, []string{labelName + ":" + labelValue})
}

func (s *Scheduler) observeAttempt(work workItem, result AttemptResult, duration time.Duration) {
	kind := string(work.job.Kind)
	outcome := string(result.Outcome)
	queueWait := s.deps.Now().Sub(work.enqueuedAt)
	if queueWait < 0 {
		queueWait = 0
	}
	if s.deps.Metrics() != nil {
		s.deps.Metrics().IncCounter("mdm_scheduler_attempts_total", metrics.Label{Name: "kind", Value: kind}, metrics.Label{Name: "outcome", Value: outcome})
		s.deps.Metrics().ObserveHistogram("mdm_scheduler_attempt_seconds", duration.Seconds(), metrics.Label{Name: "kind", Value: kind}, metrics.Label{Name: "outcome", Value: outcome})
		s.deps.Metrics().ObserveHistogram("mdm_scheduler_queue_wait_seconds", queueWait.Seconds(), metrics.Label{Name: "kind", Value: kind}, metrics.Label{Name: "priority", Value: schedulerPriorityLabel(work.job.Priority)})
		if result.Outcome == store.VerificationOutcomeTimeout {
			s.deps.Metrics().IncCounter("mdm_scheduler_timeouts_total", metrics.Label{Name: "kind", Value: kind})
		}
	}
	s.deps.Counter("mdm.scheduler.attempts", []string{"kind:" + kind, "outcome:" + outcome})
	s.deps.Histogram("mdm.scheduler.attempt_seconds", duration.Seconds(), []string{"kind:" + kind, "outcome:" + outcome})
	s.deps.Histogram("mdm.scheduler.queue_wait_seconds", queueWait.Seconds(),
		[]string{"kind:" + kind, "priority:" + schedulerPriorityLabel(work.job.Priority)})
	if result.Outcome == store.VerificationOutcomeTimeout {
		s.deps.Counter("mdm.scheduler.timeouts", []string{"kind:" + kind})
	}
	if result.Granted && work.job.Kind == store.VerificationTaskSecurityInfo {
		s.metricCounter("mdm_scheduler_grants_total", "path", "live")
	}
	if work.job.Kind == store.VerificationTaskMDA {
		mdaOutcome := outcome
		if result.Outcome == store.VerificationOutcomeSuccess {
			mdaOutcome = "verified"
		}
		s.metricCounter("mda_verification_total", "outcome", mdaOutcome)
	}
}

func (s *Scheduler) publishDogStatsDGauges() {
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
		s.deps.Gauge(value.name, value.value, value.tags)
	}
}

func (s *Scheduler) registerMetrics() {
	if s.deps.Metrics() == nil {
		return
	}
	for _, kind := range []store.VerificationTaskKind{store.VerificationTaskSecurityInfo, store.VerificationTaskMDA} {
		kind := kind
		s.deps.Metrics().RegisterGaugeLabels("mdm_scheduler_active_attempts", func() float64 {
			s.mu.Lock()
			defer s.mu.Unlock()
			return float64(s.active[kind])
		}, metrics.Label{Name: "kind", Value: string(kind)})
		for _, priority := range []store.VerificationPriority{store.VerificationPriorityFirstOrExpired, store.VerificationPriorityRecovery, store.VerificationPriorityRefresh} {
			priority := priority
			s.deps.Metrics().RegisterGaugeLabels("mdm_scheduler_queue_depth", func() float64 {
				s.mu.Lock()
				defer s.mu.Unlock()
				count := 0
				for _, job := range s.jobs {
					if !job.running && job.record.Kind == kind && job.record.Priority == priority {
						count++
					}
				}
				return float64(count)
			}, metrics.Label{Name: "kind", Value: string(kind)}, metrics.Label{Name: "priority", Value: schedulerPriorityLabel(priority)})
		}
	}
}

func (s *Scheduler) metricCounter(name, labelName, labelValue string) {
	recordCounter(s.deps, name, labelName, labelValue)
}
