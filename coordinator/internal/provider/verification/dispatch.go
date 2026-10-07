package verification

import (
	"context"
	"github.com/eigeninference/d-inference/coordinator/api/observation"
	"github.com/eigeninference/d-inference/coordinator/store"
	"time"
)

// mdmSchedulerBusyRetryDelay is the dispatcher's wake interval while due work
// exists but every worker is busy. A freed worker signals the dispatcher
// directly (finishAttempt → Wake), so this timer is only a safety net and
// need not spin at the 1 ms retry cadence used when a worker may be free.
const mdmSchedulerBusyRetryDelay = 250 * time.Millisecond

func (s *Scheduler) dispatcher() {
	defer s.wg.Done()
	// lastLoad is wall-clock so the reload cadence holds under test clocks
	// that do not advance; the due-time arithmetic itself stays on deps.Now.
	var lastLoad time.Time
	for {
		if s.shouldLoadDueRows(lastLoad) {
			s.LoadDueRows()
			lastLoad = time.Now()
		}
		s.DispatchDueRows()
		s.publishDogStatsDGauges()
		timer := s.deps.NewTimer(s.Queue.NextDispatchDelay(s.deps.Now()))
		select {
		case <-s.ctx.Done():
			timer.Stop()
			return
		case <-s.wake:
			timer.Stop()
		case <-timer.C():
		}
	}
}

// shouldLoadDueRows says whether this dispatcher pass re-reads the durable
// due rows: on the first pass, once per mdmSchedulerDispatchInterval, and
// whenever the in-memory queue is empty (so newly persisted rows are picked
// up promptly). Retry wakes — a due job that cannot run yet — used to reload
// on every 1 ms pass, which re-scanned the verification table ~34 times a
// second in production and pre-allocated a 4,096-row page each time.
func (s *Scheduler) shouldLoadDueRows(lastLoad time.Time) bool {
	if lastLoad.IsZero() || time.Since(lastLoad) >= mdmSchedulerDispatchInterval {
		return true
	}
	s.mu.Lock()
	queued := len(s.jobs)
	s.mu.Unlock()
	return queued == 0
}

func (s *Scheduler) DispatchDueRows() {
	now := s.deps.Now().UTC()
	for _, key := range s.Queue.Due(now) {
		s.claimAndDispatch(key, now)
	}
}

func (s *Scheduler) claimAndDispatch(key string, now time.Time) {
	job := s.Candidate(key)
	if job == nil || job.Running {
		return
	}
	rec := job.Record
	claimed, ok, err := s.store.ClaimVerificationJob(s.ctx, rec.SEPubKey, rec.Kind, s.owner, now, now.Add(s.config.ClaimTTL))
	if err != nil || !ok {
		if err != nil && s.ctx.Err() == nil {
			s.logger.Error("failed to claim MDM scheduler job", "error", err)
		}
		return
	}

	s.mu.Lock()
	currentJob := s.jobs[key]
	binding := s.bindings[rec.SEPubKey]
	if currentJob == nil || currentJob.Running || binding == nil || binding.Generation != currentJob.BindingGen {
		s.mu.Unlock()
		cleanupCtx, cancel := mdmSchedulerCleanupContext()
		_ = s.store.ReleaseVerificationJob(
			cleanupCtx, rec.SEPubKey, rec.Kind, s.owner, s.deps.Now().UTC(),
		)
		cancel()
		return
	}
	attemptCtx, cancel := context.WithCancel(s.ctx)
	stopAfter := context.AfterFunc(binding.Context, cancel)
	currentJob.Record = claimed
	currentJob.Running = true
	currentJob.AttemptCancel = cancel
	s.active[rec.Kind]++
	if IsUrgent(claimed) {
		s.activeUrgent++
	}
	work := mdmSchedulerWork{
		key: key, job: claimed, binding: *binding,
		ctx: attemptCtx, cancel: cancel, stopAfter: stopAfter,
		EnqueuedAt: currentJob.EnqueuedAt,
	}
	s.mu.Unlock()
	s.work <- work
}

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
			result := s.deps.Execute(work.ctx, work.binding, work.job.Kind, work.job.UDID)
			work.stopAfter()
			s.observeAttempt(work, result, s.deps.Now().Sub(started))
			s.finishAttempt(work, result)
			work.cancel()
		}
	}
}

func (s *Scheduler) finishAttempt(work mdmSchedulerWork, result AttemptResult) {
	now := s.deps.Now().UTC()
	s.mu.Lock()
	job := s.jobs[work.key]
	binding := s.bindings[work.job.SEPubKey]
	if s.active[work.job.Kind] > 0 {
		s.active[work.job.Kind]--
	}
	if IsUrgent(work.job) && s.activeUrgent > 0 {
		s.activeUrgent--
	}
	if job != nil {
		job.Running = false
		job.AttemptCancel = nil
	}
	current := job != nil && binding != nil &&
		binding.Generation == work.binding.Generation &&
		job.BindingGen == work.binding.Generation
	s.mu.Unlock()

	if !current || work.ctx.Err() != nil {
		cleanupCtx, cancel := mdmSchedulerCleanupContext()
		err := s.store.ReleaseVerificationJob(
			cleanupCtx, work.job.SEPubKey, work.job.Kind, s.owner, now,
		)
		cancel()
		if err != nil {
			s.logger.Error("failed to release stale MDM scheduler claim", "error", err)
			s.mu.Lock()
			orphan := s.jobs[work.key]
			if s.bindings[work.job.SEPubKey] == nil && orphan != nil &&
				orphan.BindingGen == work.binding.Generation {
				if orphan.Record.UDID != "" && s.byUDID[orphan.Record.UDID] == work.key {
					delete(s.byUDID, orphan.Record.UDID)
				}
				delete(s.jobs, work.key)
			}
			s.mu.Unlock()
		} else if s.ctx.Err() == nil {
			s.refreshReleasedJob(work)
		}
		s.Wake()
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
			currentJob.BindingGen == work.binding.Generation {
			currentJob.Record.UDID = result.UDID
			if currentJob.CallbackGen == work.binding.Generation &&
				currentJob.CallbackUUID != "" {
				s.byUDID[result.UDID] = work.key
			}
		}
		s.mu.Unlock()
	}

	if result.Granted || result.Terminal {
		cleanupCtx, cancel := mdmSchedulerCleanupContext()
		err := s.store.CompleteVerificationJob(
			cleanupCtx, work.job.SEPubKey, work.job.Kind,
			s.owner, result.Outcome, now,
		)
		cancel()
		if err != nil {
			s.logger.Error("failed to complete MDM scheduler job", "error", err)
		}
		s.mu.Lock()
		delete(s.jobs, work.key)
		if work.job.UDID != "" && s.byUDID[work.job.UDID] == work.key {
			delete(s.byUDID, work.job.UDID)
		}
		s.mu.Unlock()
		if result.Granted && work.job.Kind == store.VerificationTaskSecurityInfo {
			if s.deps.ReuseMDA(work.binding) {
				s.metricCounter("mda_verification_total", "outcome", "reused")
				s.mu.Lock()
				delete(s.bindings, work.job.SEPubKey)
				s.mu.Unlock()
			} else {
				s.EnqueueMDA(work.binding, result.UDID)
			}
		} else {
			s.mu.Lock()
			delete(s.bindings, work.job.SEPubKey)
			s.mu.Unlock()
		}
		s.Wake()
		return
	}

	stage := work.job.RetryStage + 1
	delay := RetryDelay(stage, s.deps.Jitter)
	priority := store.VerificationPriorityRecovery
	if work.job.Kind == store.VerificationTaskMDA {
		priority = store.VerificationPriorityRefresh
	}
	next := now.Add(delay)
	cleanupCtx, cancel := mdmSchedulerCleanupContext()
	err := s.store.RescheduleVerificationJob(
		cleanupCtx, work.job.SEPubKey, work.job.Kind, s.owner, priority, stage,
		delay, next, result.Outcome, now,
	)
	cancel()
	if err != nil {
		s.logger.Error("failed to reschedule MDM scheduler job", "error", err)
	}
	s.mu.Lock()
	if currentJob := s.jobs[work.key]; currentJob != nil &&
		currentJob.BindingGen == work.binding.Generation {
		currentJob.Record.State = store.VerificationStateBackoff
		currentJob.Record.Priority = priority
		currentJob.Record.RetryStage = stage
		currentJob.Record.PreviousDelay = delay
		currentJob.Record.NextAttemptAt = next
		currentJob.Record.LastOutcome = result.Outcome
		currentJob.Record.ClaimOwner = ""
		currentJob.Record.ClaimExpiresAt = nil
	}
	s.mu.Unlock()
	if s.observation.Metrics() != nil {
		s.observation.Metrics().ObserveHistogram(
			"mdm_scheduler_retry_delay_seconds", delay.Seconds(),
			observation.MetricLabel{Name: "stage", Value: schedulerRetryStageLabel(stage)},
		)
	}
	s.observation.Histogram("mdm.scheduler.retry_delay_seconds", delay.Seconds(), []string{"stage:" + schedulerRetryStageLabel(stage)})
	s.Wake()
}

func RetryDelay(stage int, jitter func(time.Duration, time.Duration) time.Duration) time.Duration {
	switch stage {
	case 1:
		return jitter(mdmRetryFirstMin, mdmRetryFirstMax)
	case 2:
		return jitter(mdmRetrySecondMin, mdmRetrySecondMax)
	default:
		return jitter(mdmRetrySteadyMin, mdmRetrySteadyMax)
	}
}
