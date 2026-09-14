package mdmscheduler

import (
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/telemetry/metrics"
)

func (s *Scheduler) worker() {
	defer s.wg.Done()
	for {
		select {
		case <-s.ctx.Done():
			return
		case work := <-s.work:
			if s.ctx.Err() != nil {
				work.stopAfter()
				work.cancel()
				return
			}
			started := s.deps.Now()
			result := s.deps.Execute(work.ctx, work.binding.Target(), work.job.Kind, work.job.UDID)
			work.stopAfter()
			s.observeAttempt(work, result, s.deps.Now().Sub(started))
			s.finishAttempt(work, result)
			work.cancel()
		}
	}
}

func (s *Scheduler) finishAttempt(work workItem, result AttemptResult) {
	now := s.deps.Now().UTC()
	s.mu.Lock()
	job := s.jobs[work.key]
	binding := s.bindings[work.job.SEPubKey]
	if s.active[work.job.Kind] > 0 {
		s.active[work.job.Kind]--
	}
	if isUrgentVerification(work.job) && s.activeUrgent > 0 {
		s.activeUrgent--
	}
	if job != nil {
		job.running = false
		job.attemptCancel = nil
	}
	current := job != nil && binding != nil &&
		binding.generation == work.binding.generation &&
		job.bindingGen == work.binding.generation
	s.mu.Unlock()

	if !current || work.ctx.Err() != nil {
		cleanupCtx, cancel := cleanupContext()
		err := s.store.ReleaseVerificationJob(
			cleanupCtx, work.job.SEPubKey, work.job.Kind, s.owner, now,
		)
		cancel()
		if err != nil {
			s.deps.Logger().Error("failed to release stale MDM scheduler claim", "error", err)
			s.mu.Lock()
			orphan := s.jobs[work.key]
			if s.bindings[work.job.SEPubKey] == nil && orphan != nil &&
				orphan.bindingGen == work.binding.generation {
				if orphan.record.UDID != "" && s.byUDID[orphan.record.UDID] == work.key {
					delete(s.byUDID, orphan.record.UDID)
				}
				delete(s.jobs, work.key)
			}
			s.mu.Unlock()
		} else if s.ctx.Err() == nil {
			s.refreshReleasedJob(work)
		}
		s.signal()
		return
	}

	if result.UDID != "" {
		work.job.UDID = result.UDID
		work.job.UpdatedAt = now
		if updated, err := s.store.UpsertVerificationJob(s.ctx, work.job); err == nil {
			work.job = updated
		}
		s.mu.Lock()
		if currentJob := s.jobs[work.key]; currentJob != nil &&
			currentJob.bindingGen == work.binding.generation {
			currentJob.record.UDID = result.UDID
			if currentJob.callbackGen == work.binding.generation &&
				currentJob.callbackUUID != "" {
				s.byUDID[result.UDID] = work.key
			}
		}
		s.mu.Unlock()
	}

	if result.Granted || result.Terminal {
		cleanupCtx, cancel := cleanupContext()
		err := s.store.CompleteVerificationJob(
			cleanupCtx, work.job.SEPubKey, work.job.Kind,
			s.owner, result.Outcome, now,
		)
		cancel()
		if err != nil {
			s.deps.Logger().Error("failed to complete MDM scheduler job", "error", err)
		}
		s.mu.Lock()
		delete(s.jobs, work.key)
		if work.job.UDID != "" && s.byUDID[work.job.UDID] == work.key {
			delete(s.byUDID, work.job.UDID)
		}
		s.mu.Unlock()
		if result.Granted && work.job.Kind == store.VerificationTaskSecurityInfo {
			s.finishSecurityInfo(work.binding, result.UDID)
		} else {
			s.forgetBinding(work.binding)
		}
		s.signal()
		return
	}

	stage := work.job.RetryStage + 1
	delay := s.retryDelay(stage)
	priority := store.VerificationPriorityRecovery
	if work.job.Kind == store.VerificationTaskMDA {
		priority = store.VerificationPriorityRefresh
	}
	next := now.Add(delay)
	cleanupCtx, cancel := cleanupContext()
	err := s.store.RescheduleVerificationJob(
		cleanupCtx, work.job.SEPubKey, work.job.Kind, s.owner, priority, stage,
		delay, next, result.Outcome, now,
	)
	cancel()
	if err != nil {
		s.deps.Logger().Error("failed to reschedule MDM scheduler job", "error", err)
	}
	s.mu.Lock()
	if currentJob := s.jobs[work.key]; currentJob != nil &&
		currentJob.bindingGen == work.binding.generation {
		currentJob.record.State = store.VerificationStateBackoff
		currentJob.record.Priority = priority
		currentJob.record.RetryStage = stage
		currentJob.record.PreviousDelay = delay
		currentJob.record.NextAttemptAt = next
		currentJob.record.LastOutcome = result.Outcome
		currentJob.record.ClaimOwner = ""
		currentJob.record.ClaimExpiresAt = nil
	}
	s.mu.Unlock()
	if s.deps.Metrics() != nil {
		s.deps.Metrics().ObserveHistogram(
			"mdm_scheduler_retry_delay_seconds", delay.Seconds(),
			metrics.Label{Name: "stage", Value: schedulerRetryStageLabel(stage)},
		)
	}
	s.deps.Histogram("mdm.scheduler.retry_delay_seconds", delay.Seconds(), []string{"stage:" + schedulerRetryStageLabel(stage)})
	s.signal()
}
