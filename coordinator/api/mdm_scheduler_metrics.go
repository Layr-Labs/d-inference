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

func (s *mdmVerificationScheduler) observeAttempt(work mdmSchedulerWork, result mdmSchedulerAttemptResult, duration time.Duration) {
	kind := string(work.job.Kind)
	outcome := string(result.outcome)
	queueWait := s.deps.now().Sub(work.enqueuedAt)
	if queueWait < 0 {
		queueWait = 0
	}
	m := s.server.metrics().MDMScheduler
	m.Attempts.Inc(kind, outcome)
	m.AttemptSeconds.Observe(duration.Seconds(), kind, outcome)
	m.QueueWaitSeconds.Observe(queueWait.Seconds(), kind, schedulerPriorityLabel(work.job.Priority))
	if result.outcome == store.VerificationOutcomeTimeout {
		m.Timeouts.Inc(kind)
	}
	if result.granted && work.job.Kind == store.VerificationTaskSecurityInfo {
		m.Grants.Inc("live")
	}
	if work.job.Kind == store.VerificationTaskMDA {
		mdaOutcome := outcome
		if result.outcome == store.VerificationOutcomeSuccess {
			mdaOutcome = "verified"
		}
		s.server.metrics().Trust.MDAVerification.Inc(mdaOutcome)
	}
}

// publishDogStatsDGauges pushes the queue's current shape. A pushed gauge is
// only remembered for the flush window it was sent in, which is why this runs on
// the gauge loop rather than at the events that change these numbers.
func (s *mdmVerificationScheduler) publishDogStatsDGauges() {
	type gauge struct {
		set   func(float64, ...string)
		value float64
		tags  []string
	}
	m := s.server.metrics().MDMScheduler
	values := make([]gauge, 0, 8)
	s.mu.Lock()
	for _, kind := range []store.VerificationTaskKind{
		store.VerificationTaskSecurityInfo, store.VerificationTaskMDA,
	} {
		values = append(values, gauge{
			set:   m.ActiveAttempts.Set,
			value: float64(s.active[kind]),
			tags:  []string{string(kind)},
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
				set: m.QueueDepth.Set, value: float64(count),
				tags: []string{
					string(kind),
					schedulerPriorityLabel(priority),
				},
			})
		}
	}
	s.mu.Unlock()
	for _, value := range values {
		value.set(value.value, value.tags...)
	}
}

func (s *mdmVerificationScheduler) registerMetrics() {
	if s.server.adminMetrics == nil {
		return
	}
	for _, kind := range []store.VerificationTaskKind{store.VerificationTaskSecurityInfo, store.VerificationTaskMDA} {
		kind := kind
		s.server.adminMetrics.RegisterGaugeLabels("mdm_scheduler_active_attempts", func() float64 {
			s.mu.Lock()
			defer s.mu.Unlock()
			return float64(s.active[kind])
		}, MetricLabel{"kind", string(kind)})
		for _, priority := range []store.VerificationPriority{store.VerificationPriorityFirstOrExpired, store.VerificationPriorityRecovery, store.VerificationPriorityRefresh} {
			priority := priority
			s.server.adminMetrics.RegisterGaugeLabels("mdm_scheduler_queue_depth", func() float64 {
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
