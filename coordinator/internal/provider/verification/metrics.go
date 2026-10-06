package verification

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/observation"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// Observer owns scheduler event instrumentation independently of dispatch state.
// The driver and external command executors report through this same observer.
type Observer struct {
	observation *observation.Owner
	now         func() time.Time
}

func NewObserver(observation *observation.Owner, now func() time.Time) *Observer {
	if now == nil {
		now = time.Now
	}
	return &Observer{observation: observation, now: now}
}

// ObserveMDASent records the command handoff performed by the owner's executor.
func (s *Scheduler) ObserveMDASent() {
	s.metricCounter("mda_verification_total", "outcome", "sent")
}

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

func (s *Scheduler) metricCounter(name, labelName, labelValue string) {
	s.observer.Counter(name, labelName, labelValue)
}

func (s *Observer) Counter(name, labelName, labelValue string) {
	if s.observation.Metrics() != nil {
		s.observation.Metrics().IncCounter(name, observation.MetricLabel{Name: labelName, Value: labelValue})
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
	s.observation.Incr(ddName, []string{labelName + ":" + labelValue})
}

func (s *Scheduler) observeAttempt(work mdmSchedulerWork, result AttemptResult, duration time.Duration) {
	s.observer.Attempt(work.job, work.EnqueuedAt, result, duration)
}

func (s *Observer) Attempt(job store.VerificationJob, enqueuedAt time.Time, result AttemptResult, duration time.Duration) {
	kind := string(job.Kind)
	outcome := string(result.Outcome)
	queueWait := s.now().Sub(enqueuedAt)
	if queueWait < 0 {
		queueWait = 0
	}
	if s.observation.Metrics() != nil {
		s.observation.Metrics().IncCounter("mdm_scheduler_attempts_total", observation.MetricLabel{Name: "kind", Value: kind}, observation.MetricLabel{Name: "outcome", Value: outcome})
		s.observation.Metrics().ObserveHistogram("mdm_scheduler_attempt_seconds", duration.Seconds(), observation.MetricLabel{Name: "kind", Value: kind}, observation.MetricLabel{Name: "outcome", Value: outcome})
		s.observation.Metrics().ObserveHistogram("mdm_scheduler_queue_wait_seconds", queueWait.Seconds(), observation.MetricLabel{Name: "kind", Value: kind}, observation.MetricLabel{Name: "priority", Value: schedulerPriorityLabel(job.Priority)})
		if result.Outcome == store.VerificationOutcomeTimeout {
			s.observation.Metrics().IncCounter("mdm_scheduler_timeouts_total", observation.MetricLabel{Name: "kind", Value: kind})
		}
	}
	s.observation.Incr("mdm.scheduler.attempts", []string{"kind:" + kind, "Outcome:" + outcome})
	s.observation.Histogram("mdm.scheduler.attempt_seconds", duration.Seconds(), []string{"kind:" + kind, "Outcome:" + outcome})
	s.observation.Histogram("mdm.scheduler.queue_wait_seconds", queueWait.Seconds(),
		[]string{"kind:" + kind, "priority:" + schedulerPriorityLabel(job.Priority)})
	if result.Outcome == store.VerificationOutcomeTimeout {
		s.observation.Incr("mdm.scheduler.timeouts", []string{"kind:" + kind})
	}
	if result.Granted && job.Kind == store.VerificationTaskSecurityInfo {
		s.Counter("mdm_scheduler_grants_total", "path", "live")
	}
	if job.Kind == store.VerificationTaskMDA {
		mdaOutcome := outcome
		if result.Outcome == store.VerificationOutcomeSuccess {
			mdaOutcome = "verified"
		}
		s.Counter("mda_verification_total", "outcome", mdaOutcome)
	}
}

func (s *Scheduler) publishDogStatsDGauges() {
	type gauge struct {
		name  string
		value float64
		tags  []string
	}
	values := make([]gauge, 0, 8)
	status := s.Status()
	for _, kind := range []store.VerificationTaskKind{
		store.VerificationTaskSecurityInfo, store.VerificationTaskMDA,
	} {
		values = append(values, gauge{
			name:  "mdm.scheduler.active_attempts",
			value: float64(status.Active[kind]),
			tags:  []string{"kind:" + string(kind)},
		})
		for _, priority := range []store.VerificationPriority{
			store.VerificationPriorityFirstOrExpired,
			store.VerificationPriorityRecovery,
			store.VerificationPriorityRefresh,
		} {
			count := status.Depth[kind][priority]
			values = append(values, gauge{
				name: "mdm.scheduler.queue_depth", value: float64(count),
				tags: []string{
					"kind:" + string(kind),
					"priority:" + schedulerPriorityLabel(priority),
				},
			})
		}
	}
	for _, value := range values {
		s.observation.Gauge(value.name, value.value, value.tags)
	}
}

func (s *Scheduler) registerMetrics() {
	if s.observation.Metrics() == nil {
		return
	}
	for _, kind := range []store.VerificationTaskKind{store.VerificationTaskSecurityInfo, store.VerificationTaskMDA} {
		kind := kind
		s.observation.Metrics().RegisterGaugeLabels("mdm_scheduler_active_attempts", func() float64 {
			s.mu.Lock()
			defer s.mu.Unlock()
			return float64(s.active[kind])
		}, observation.MetricLabel{Name: "kind", Value: string(kind)})
		for _, priority := range []store.VerificationPriority{store.VerificationPriorityFirstOrExpired, store.VerificationPriorityRecovery, store.VerificationPriorityRefresh} {
			priority := priority
			s.observation.Metrics().RegisterGaugeLabels("mdm_scheduler_queue_depth", func() float64 {
				s.mu.Lock()
				defer s.mu.Unlock()
				count := 0
				for _, job := range s.jobs {
					if !job.Running && job.Record.Kind == kind && job.Record.Priority == priority {
						count++
					}
				}
				return float64(count)
			}, observation.MetricLabel{Name: "kind", Value: string(kind)}, observation.MetricLabel{Name: "priority", Value: schedulerPriorityLabel(priority)})
		}
	}
}
