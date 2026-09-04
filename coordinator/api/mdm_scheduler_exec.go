package api

import (
	"context"
	"sort"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

func (s *mdmVerificationScheduler) dispatcher() {
	defer s.wg.Done()
	var (
		lastLoad     time.Time // deps.now() at the last load (the injectable clock)
		lastLoadWall time.Time // time.Now() at the last load (the clock the timer runs on)
	)
	for {
		// Durable due rows are (re)loaded at most once per dispatch interval.
		// Wakes and the 1 ms retry path (due work that cannot dispatch because
		// every worker is busy) dispatch from the in-memory queue without
		// re-scanning the table: with a busy pool that path re-queried
		// provider_verification_jobs on every iteration (≈34 scans/s in prod,
		// each pre-allocating a full page). Newly-due rows are picked up
		// within one interval — the cadence they were always polled at when
		// nothing was due. The gate honours whichever clock advanced: the
		// injectable one (tests jump it) or the wall clock the retry timer
		// keeps (tests freeze the injectable one; in production they agree).
		now, wall := s.deps.now(), time.Now()
		if lastLoadWall.IsZero() || dispatchIntervalElapsed(lastLoad, now) || dispatchIntervalElapsed(lastLoadWall, wall) {
			s.loadDueRows()
			lastLoad, lastLoadWall = now, wall
		}
		s.dispatchDueRows()
		s.publishDogStatsDGauges()
		timer := s.deps.newTimer(s.nextDispatchDelay())
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

// dispatchIntervalElapsed reports whether a full dispatch interval has passed
// on one clock since `since` (a clock that moved backwards counts as elapsed).
func dispatchIntervalElapsed(since, now time.Time) bool {
	return now.Before(since) || now.Sub(since) >= mdmSchedulerDispatchInterval
}

func (s *mdmVerificationScheduler) nextDispatchDelay() time.Duration {
	now := s.deps.now()
	delay := mdmSchedulerDispatchInterval
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, job := range s.jobs {
		if job.running || (job.record.State != store.VerificationStatePending && job.record.State != store.VerificationStateBackoff) {
			continue
		}
		candidate := job.record.NextAttemptAt.Sub(now)
		if candidate <= 0 {
			return time.Millisecond
		}
		if candidate < delay {
			delay = candidate
		}
	}
	return delay
}

func (s *mdmVerificationScheduler) dispatchDueRows() {
	now := s.deps.now().UTC()
	type candidate struct {
		key string
		rec store.VerificationJob
	}
	s.mu.Lock()
	available := s.cfg.Workers
	for _, count := range s.active {
		available -= count
	}
	// Of the free slots, hold back any unused reserved urgent capacity so
	// refresh/recovery work can never occupy the last worker while urgent
	// first/expired SecurityInfo work may still arrive.
	reservedFree := s.reservedUrgentSlots() - s.activeUrgent
	if reservedFree < 0 {
		reservedFree = 0
	}
	generalAvailable := available - reservedFree
	candidates := make([]candidate, 0, available)
	if available > 0 {
		for key, job := range s.jobs {
			binding := s.bindings[job.record.SEPubKey]
			if job.running || binding == nil || binding.generation != job.bindingGen {
				continue
			}
			if job.record.Kind == store.VerificationTaskSecurityInfo && !binding.challengeSettled {
				continue
			}
			if job.record.Kind == store.VerificationTaskMDA &&
				(!binding.challengeSettled || !binding.allowMDA) {
				continue
			}
			claimExpired := job.record.State == store.VerificationStateRunning &&
				job.record.ClaimExpiresAt != nil &&
				!job.record.ClaimExpiresAt.After(now)
			durableDue := job.record.State == store.VerificationStatePending ||
				job.record.State == store.VerificationStateBackoff ||
				claimExpired
			if durableDue && !job.record.NextAttemptAt.After(now) {
				candidates = append(candidates, candidate{key: key, rec: job.record})
			}
		}
	}
	s.mu.Unlock()
	sort.Slice(candidates, func(i, j int) bool {
		if candidates[i].rec.Priority != candidates[j].rec.Priority {
			return candidates[i].rec.Priority < candidates[j].rec.Priority
		}
		return candidates[i].rec.NextAttemptAt.Before(candidates[j].rec.NextAttemptAt)
	})
	selected := candidates[:0]
	for _, c := range candidates {
		if available <= 0 {
			break
		}
		if !isUrgentVerification(c.rec) {
			if generalAvailable <= 0 {
				continue
			}
			generalAvailable--
		}
		available--
		selected = append(selected, c)
	}
	for _, candidate := range selected {
		s.claimAndDispatch(candidate.key, now)
	}
}

func (s *mdmVerificationScheduler) claimAndDispatch(key string, now time.Time) {
	s.mu.Lock()
	job := s.jobs[key]
	if job == nil || job.running {
		s.mu.Unlock()
		return
	}
	rec := job.record
	s.mu.Unlock()
	claimed, ok, err := s.store.ClaimVerificationJob(s.ctx, rec.SEPubKey, rec.Kind, s.owner, now, now.Add(s.cfg.ClaimTTL))
	if err != nil || !ok {
		if err != nil && s.ctx.Err() == nil {
			s.server.logger.Error("failed to claim MDM scheduler job", "error", err)
		}
		return
	}

	s.mu.Lock()
	job = s.jobs[key]
	binding := s.bindings[rec.SEPubKey]
	if job == nil || job.running || binding == nil || binding.generation != job.bindingGen {
		s.mu.Unlock()
		cleanupCtx, cancel := mdmSchedulerCleanupContext()
		_ = s.store.ReleaseVerificationJob(
			cleanupCtx, rec.SEPubKey, rec.Kind, s.owner, s.deps.now().UTC(),
		)
		cancel()
		return
	}
	attemptCtx, cancel := context.WithCancel(s.ctx)
	stopAfter := context.AfterFunc(binding.ctx, cancel)
	job.record = claimed
	job.running = true
	job.attemptCancel = cancel
	s.active[rec.Kind]++
	if isUrgentVerification(claimed) {
		s.activeUrgent++
	}
	work := mdmSchedulerWork{
		key: key, job: claimed, binding: *binding,
		ctx: attemptCtx, cancel: cancel, stopAfter: stopAfter,
		enqueuedAt: job.enqueuedAt,
	}
	s.mu.Unlock()
	s.work <- work
}

func (s *mdmVerificationScheduler) worker() {
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
			started := s.deps.now()
			result := s.deps.execute(work.ctx, work.binding, work.job.Kind, work.job.UDID)
			work.stopAfter()
			s.observeAttempt(work, result, s.deps.now().Sub(started))
			s.finishAttempt(work, result)
			work.cancel()
		}
	}
}

func (s *mdmVerificationScheduler) finishAttempt(work mdmSchedulerWork, result mdmSchedulerAttemptResult) {
	now := s.deps.now().UTC()
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
		cleanupCtx, cancel := mdmSchedulerCleanupContext()
		err := s.store.ReleaseVerificationJob(
			cleanupCtx, work.job.SEPubKey, work.job.Kind, s.owner, now,
		)
		cancel()
		if err != nil {
			s.server.logger.Error("failed to release stale MDM scheduler claim", "error", err)
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

	if result.udid != "" {
		work.job.UDID = result.udid
		work.job.UpdatedAt = now
		if updated, err := s.store.UpsertVerificationJob(s.ctx, work.job); err == nil {
			work.job = updated
		}
		s.mu.Lock()
		if currentJob := s.jobs[work.key]; currentJob != nil &&
			currentJob.bindingGen == work.binding.generation {
			currentJob.record.UDID = result.udid
			if currentJob.callbackGen == work.binding.generation &&
				currentJob.callbackUUID != "" {
				s.byUDID[result.udid] = work.key
			}
		}
		s.mu.Unlock()
	}

	if result.granted || result.terminal {
		cleanupCtx, cancel := mdmSchedulerCleanupContext()
		err := s.store.CompleteVerificationJob(
			cleanupCtx, work.job.SEPubKey, work.job.Kind,
			s.owner, result.outcome, now,
		)
		cancel()
		if err != nil {
			s.server.logger.Error("failed to complete MDM scheduler job", "error", err)
		}
		s.mu.Lock()
		delete(s.jobs, work.key)
		if work.job.UDID != "" && s.byUDID[work.job.UDID] == work.key {
			delete(s.byUDID, work.job.UDID)
		}
		s.mu.Unlock()
		if result.granted && work.job.Kind == store.VerificationTaskSecurityInfo {
			if s.deps.reuseMDA(work.binding) {
				s.metricCounter("mda_verification_total", "outcome", "reused")
				s.mu.Lock()
				delete(s.bindings, work.job.SEPubKey)
				s.mu.Unlock()
			} else {
				s.enqueueMDA(work.binding, result.udid)
			}
		} else {
			s.mu.Lock()
			delete(s.bindings, work.job.SEPubKey)
			s.mu.Unlock()
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
	cleanupCtx, cancel := mdmSchedulerCleanupContext()
	err := s.store.RescheduleVerificationJob(
		cleanupCtx, work.job.SEPubKey, work.job.Kind, s.owner, priority, stage,
		delay, next, result.outcome, now,
	)
	cancel()
	if err != nil {
		s.server.logger.Error("failed to reschedule MDM scheduler job", "error", err)
	}
	s.mu.Lock()
	if currentJob := s.jobs[work.key]; currentJob != nil &&
		currentJob.bindingGen == work.binding.generation {
		currentJob.record.State = store.VerificationStateBackoff
		currentJob.record.Priority = priority
		currentJob.record.RetryStage = stage
		currentJob.record.PreviousDelay = delay
		currentJob.record.NextAttemptAt = next
		currentJob.record.LastOutcome = result.outcome
		currentJob.record.ClaimOwner = ""
		currentJob.record.ClaimExpiresAt = nil
	}
	s.mu.Unlock()
	if s.server.metrics != nil {
		s.server.metrics.ObserveHistogram(
			"mdm_scheduler_retry_delay_seconds", delay.Seconds(),
			MetricLabel{"stage", schedulerRetryStageLabel(stage)},
		)
	}
	s.server.ddHistogram("mdm.scheduler.retry_delay_seconds", delay.Seconds(), []string{"stage:" + schedulerRetryStageLabel(stage)})
	s.signal()
}

func (s *mdmVerificationScheduler) retryDelay(stage int) time.Duration {
	switch stage {
	case 1:
		return s.deps.jitter(mdmRetryFirstMin, mdmRetryFirstMax)
	case 2:
		return s.deps.jitter(mdmRetrySecondMin, mdmRetrySecondMax)
	default:
		return s.deps.jitter(mdmRetrySteadyMin, mdmRetrySteadyMax)
	}
}

type mdmSchedulerAttemptMetadata struct {
	udid       string
	mdaOutcome string
}
type mdmSchedulerAttemptContextKey struct{}

func (s *Server) executeScheduledVerification(ctx context.Context, binding mdmLiveBinding, kind store.VerificationTaskKind, udid string) mdmSchedulerAttemptResult {
	if binding.provider == nil || binding.provider.ChallengeShouldStop() {
		return mdmSchedulerAttemptResult{outcome: store.VerificationOutcomePostureMismatch, terminal: true}
	}
	metadata := &mdmSchedulerAttemptMetadata{}
	ctx = context.WithValue(ctx, mdmSchedulerAttemptContextKey{}, metadata)
	if kind == store.VerificationTaskSecurityInfo {
		outcome := s.verifyProviderViaMDM(ctx, binding.providerID, binding.provider, binding.attestation)
		switch outcome {
		case mdmVerifyGranted:
			return mdmSchedulerAttemptResult{outcome: store.VerificationOutcomeSuccess, granted: true, udid: metadata.udid}
		case mdmVerifyTerminal:
			return mdmSchedulerAttemptResult{outcome: store.VerificationOutcomePostureMismatch, terminal: true, udid: metadata.udid}
		default:
			fixed := store.VerificationOutcomeTransient
			if binding.provider.GetMDMFailureReason() == "securityinfo-timeout" {
				fixed = store.VerificationOutcomeTimeout
			}
			return mdmSchedulerAttemptResult{outcome: fixed, udid: metadata.udid}
		}
	}
	if udid == "" {
		return mdmSchedulerAttemptResult{outcome: store.VerificationOutcomeInvalid, terminal: true}
	}
	s.mdmScheduler.metricCounter("mda_verification_total", "outcome", "sent")
	s.verifyAppleDeviceAttestation(ctx, binding.providerID, binding.provider, binding.attestation, udid)
	if ctx.Err() != nil {
		return mdmSchedulerAttemptResult{outcome: store.VerificationOutcomeCancelled}
	}
	binding.provider.Mu().Lock()
	verified := binding.provider.MDAVerified
	binding.provider.Mu().Unlock()
	if verified {
		return mdmSchedulerAttemptResult{outcome: store.VerificationOutcomeSuccess, granted: true, udid: udid}
	}
	if binding.provider.ChallengeShouldStop() {
		return mdmSchedulerAttemptResult{outcome: store.VerificationOutcomeInvalid, terminal: true, udid: udid}
	}
	if metadata.mdaOutcome == "timeout" {
		return mdmSchedulerAttemptResult{outcome: store.VerificationOutcomeTimeout, udid: udid}
	}
	if metadata.mdaOutcome == "invalid" ||
		metadata.mdaOutcome == "binding_mismatch" {
		return mdmSchedulerAttemptResult{
			outcome: store.VerificationOutcomeInvalid, terminal: true, udid: udid,
		}
	}
	return mdmSchedulerAttemptResult{outcome: store.VerificationOutcomeTransient, udid: udid}
}
