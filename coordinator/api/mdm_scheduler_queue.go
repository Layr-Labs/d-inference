package api

import (
	"context"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func (s *mdmVerificationScheduler) Submit(ctx context.Context, providerID string, provider *registry.Provider, priority store.VerificationPriority) uint64 {
	if s == nil || provider == nil {
		return 0
	}
	result := provider.GetAttestationResult()
	if result == nil || !result.Valid || result.PublicKey == "" || result.SerialNumber == "" {
		return 0
	}
	s.Start()
	now := s.deps.now().UTC()
	record, err := s.store.UpsertVerificationJob(ctx, store.VerificationJob{
		SEPubKey: result.PublicKey, Serial: result.SerialNumber,
		Kind:     store.VerificationTaskSecurityInfo,
		State:    store.VerificationStateWaitingChallenge,
		Priority: priority, LastOutcome: store.VerificationOutcomeNone,
		UpdatedAt: now,
	})
	if err != nil {
		s.server.logger.Error("failed to persist MDM scheduler submission", "error", err)
		s.metricCounter("mdm_scheduler_queue_rejected_total", "priority", schedulerPriorityLabel(priority))
		return 0
	}

	seKey := result.PublicKey
	key := verificationSchedulerKey(seKey, record.Kind)
	s.mu.Lock()
	generation := s.generation.Add(1)
	binding := &mdmLiveBinding{
		providerID: providerID, provider: provider, attestation: *result,
		generation: generation, ctx: ctx,
	}
	s.bindings[seKey] = binding
	for otherKey, other := range s.jobs {
		if other.record.SEPubKey != seKey || other.record.Kind != store.VerificationTaskMDA {
			continue
		}
		if other.attemptCancel != nil {
			other.attemptCancel()
		}
		if other.record.UDID != "" && s.byUDID[other.record.UDID] == otherKey {
			delete(s.byUDID, other.record.UDID)
		}
		delete(s.jobs, otherKey)
	}
	if existing := s.jobs[key]; existing != nil {
		if existing.attemptCancel != nil {
			existing.attemptCancel()
		}
		if existing.record.UDID != "" && s.byUDID[existing.record.UDID] == key {
			delete(s.byUDID, existing.record.UDID)
		}
		existing.record = record
		existing.bindingGen = generation
		existing.callbackGen = 0
		existing.callbackUUID = ""
		existing.enqueuedAt = now
		s.mu.Unlock()
		s.metricCounter("mdm_scheduler_deduplicated_total", "state", string(record.State))
		s.signal()
		return generation
	}
	if record.State == store.VerificationStateRunning &&
		record.ClaimOwner != "" && record.ClaimOwner != s.owner {
		s.mu.Unlock()
		s.metricCounter("mdm_scheduler_deduplicated_total", "state", string(record.State))
		s.signal()
		return generation
	}
	if !s.makeQueueRoomLocked(priority) {
		s.mu.Unlock()
		s.metricCounter("mdm_scheduler_queue_rejected_total", "priority", schedulerPriorityLabel(priority))
		s.signal()
		return generation
	}
	s.jobs[key] = &mdmScheduledJob{record: record, bindingGen: generation, enqueuedAt: now}
	s.mu.Unlock()
	s.metricCounter("mdm_scheduler_enqueued_total", "reason", "registration")
	s.signal()
	return generation
}

// makeQueueRoomLocked never evicts first/expired or recovery work. An evicted
// refresh remains durable and is reloaded only when bounded memory has room.
func (s *mdmVerificationScheduler) makeQueueRoomLocked(priority store.VerificationPriority) bool {
	if len(s.jobs) < s.cfg.QueueCapacity {
		return true
	}
	if priority == store.VerificationPriorityRefresh {
		return false
	}
	for key, job := range s.jobs {
		if !job.running && job.record.Priority == store.VerificationPriorityRefresh {
			delete(s.jobs, key)
			if job.record.UDID != "" && s.byUDID[job.record.UDID] == key {
				delete(s.byUDID, job.record.UDID)
			}
			return true
		}
	}
	return false
}

// PromoteFailedFastSkip re-classifies this connection's SecurityInfo work as
// first/expired after the trust-reuse fast-skip DECLINED (Codex P1). The
// submit-time classification (hasFreshRecord → refresh spread) was optimistic:
// the read gate refused the record — a deactivated predecessor transition, a
// continuity gap outgrown between submit and challenge, a posture/serial
// mismatch — so the provider holds NO usable trust grant while routed client
// requests burn the 120s dispatch-queue deadline. The subsequent
// ChallengeSettled(provider, false) then computes the immediate first/expired
// due time and persists the promoted priority. Recovery work keeps its
// preserved due semantics and is not promoted.
func (s *mdmVerificationScheduler) PromoteFailedFastSkip(provider *registry.Provider) {
	if s == nil || provider == nil {
		return
	}
	result := provider.GetAttestationResult()
	if result == nil || result.PublicKey == "" {
		return
	}
	s.mu.Lock()
	if binding := s.bindings[result.PublicKey]; binding != nil && binding.provider == provider {
		binding.promoteFirstOrExpired = true
	}
	s.mu.Unlock()
}

// ChallengeSettled gates all SecurityInfo work on the current connection's
// phase-1 challenge. A fast-skip completes the durable row before any worker or
// MDM command is consumed.
func (s *mdmVerificationScheduler) ChallengeSettled(provider *registry.Provider, fastSkip bool) {
	if s == nil || provider == nil {
		return
	}
	result := provider.GetAttestationResult()
	if result == nil || result.PublicKey == "" {
		return
	}
	seKey := result.PublicKey
	key := verificationSchedulerKey(seKey, store.VerificationTaskSecurityInfo)
	now := s.deps.now().UTC()
	if fastSkip {
		s.mu.Lock()
		binding := s.bindings[seKey]
		job := s.jobs[key]
		if binding == nil || binding.provider != provider {
			s.mu.Unlock()
			return
		}
		owner := ""
		if job != nil {
			owner = job.record.ClaimOwner
			if job.attemptCancel != nil {
				job.attemptCancel()
			}
			delete(s.jobs, key)
		}
		delete(s.bindings, seKey)
		s.mu.Unlock()
		cleanupCtx, cancel := mdmSchedulerCleanupContext()
		err := s.store.CompleteVerificationJob(
			cleanupCtx, seKey, store.VerificationTaskSecurityInfo, owner,
			store.VerificationOutcomeReused, now,
		)
		cancel()
		if err != nil {
			s.server.logger.Error("failed to complete fast-skip scheduler job", "error", err)
		}
		s.metricCounter("mdm_scheduler_cancelled_total", "reason", "fast_skip")
		s.metricCounter("mdm_scheduler_grants_total", "path", "reuse")
		s.signal()
		return
	}

	s.mu.Lock()
	binding := s.bindings[seKey]
	if binding == nil || binding.provider != provider {
		s.mu.Unlock()
		return
	}
	binding.challengeSettled = true
	promote := binding.promoteFirstOrExpired
	generation := binding.generation
	job := s.jobs[key]
	var record *store.VerificationJob
	if job != nil {
		copy := job.record
		record = &copy
	}
	s.mu.Unlock()

	if record == nil {
		durable, err := s.store.GetVerificationJob(s.ctx, seKey, store.VerificationTaskSecurityInfo)
		if err != nil {
			s.server.logger.Error("failed to load queue-rejected MDM scheduler job", "error", err)
			return
		}
		if durable == nil {
			s.signal()
			return
		}
		record = durable
	}

	s.mu.Lock()
	currentBinding := s.bindings[seKey]
	stillCurrent := currentBinding != nil &&
		currentBinding.provider == provider &&
		currentBinding.generation == generation &&
		currentBinding.challengeSettled
	s.mu.Unlock()
	if !stillCurrent {
		return
	}

	if promote && record.Priority == store.VerificationPriorityRefresh {
		record.Priority = store.VerificationPriorityFirstOrExpired
	}
	record.State = store.VerificationStatePending
	record.NextAttemptAt = now.Add(s.initialSpread(record.Priority))
	record.UpdatedAt = now
	updated, err := s.store.UpsertVerificationJob(s.ctx, *record)
	if err != nil {
		s.server.logger.Error("failed to make MDM scheduler job eligible", "error", err)
		return
	}
	s.mu.Lock()
	if current := s.jobs[key]; current != nil && current.bindingGen == generation {
		current.record = updated
	}
	s.mu.Unlock()
	s.signal()
}

// initialSpread is the delay before the first attempt once the phase-1
// challenge settles. First/expired work backs a provider with no usable trust
// grant — client requests routed to it queue against the 120s dispatch
// deadline — so it becomes due essentially immediately, with at most a tiny
// jitter (never past mdmFirstVerifySpreadMax) to de-synchronise mass expiry.
// Refresh and recovery work still holds a valid grant and keeps the full
// configured spread so routine releases and coordinator restarts never
// stampede MDM.
func (s *mdmVerificationScheduler) initialSpread(priority store.VerificationPriority) time.Duration {
	if priority == store.VerificationPriorityFirstOrExpired {
		return s.deps.jitter(0, min(s.cfg.InitialSpreadMax, mdmFirstVerifySpreadMax))
	}
	return s.deps.jitter(s.cfg.InitialSpreadMin, s.cfg.InitialSpreadMax)
}

func (s *mdmVerificationScheduler) Unbind(seKey string, generation uint64) {
	if s == nil || seKey == "" || generation == 0 {
		return
	}
	s.mu.Lock()
	binding := s.bindings[seKey]
	if binding == nil || binding.generation != generation {
		s.mu.Unlock()
		return
	}
	delete(s.bindings, seKey)
	for key, job := range s.jobs {
		if job.record.SEPubKey != seKey || job.bindingGen != generation {
			continue
		}
		if job.attemptCancel != nil {
			job.attemptCancel()
		}
		if job.record.UDID != "" && s.byUDID[job.record.UDID] == key {
			delete(s.byUDID, job.record.UDID)
		}
		if !job.running {
			delete(s.jobs, key)
		}
	}
	s.mu.Unlock()
	s.metricCounter("mdm_scheduler_cancelled_total", "reason", "disconnect")
	s.signal()
}

func (s *mdmVerificationScheduler) loadDueRows() {
	now := s.deps.now().UTC()
	limit := s.cfg.QueueCapacity
	s.mu.Lock()
	offset := s.dueScanOffset
	s.mu.Unlock()

	var (
		rows []store.VerificationJob
		err  error
	)
	if paged, ok := s.store.(verificationDuePageStore); ok {
		rows, err = paged.ListDueVerificationJobsPage(
			s.ctx, now, limit, offset,
		)
	} else {
		rows, err = s.store.ListDueVerificationJobs(s.ctx, now, limit)
		offset = 0
	}
	if err != nil {
		if s.ctx.Err() == nil {
			s.server.logger.Error("failed to load due MDM scheduler rows", "error", err)
		}
		return
	}
	s.mu.Lock()
	if len(rows) < limit {
		s.dueScanOffset = 0
	} else {
		s.dueScanOffset = offset + len(rows)
	}
	for _, rec := range rows {
		key := verificationSchedulerKey(rec.SEPubKey, rec.Kind)
		binding := s.bindings[rec.SEPubKey]
		if binding == nil ||
			(rec.Kind == store.VerificationTaskSecurityInfo && !binding.challengeSettled) ||
			(rec.Kind == store.VerificationTaskMDA && (!binding.challengeSettled || !binding.allowMDA)) {
			continue
		}
		if existing := s.jobs[key]; existing != nil {
			claimExpired := rec.State == store.VerificationStateRunning &&
				rec.ClaimExpiresAt != nil && !rec.ClaimExpiresAt.After(now)
			stalePlaceholder := !existing.running &&
				rec.ClaimOwner != s.owner &&
				claimExpired
			if !stalePlaceholder {
				continue
			}
			if oldUDID := existing.record.UDID; oldUDID != "" &&
				s.byUDID[oldUDID] == key {
				delete(s.byUDID, oldUDID)
			}
			existing.record = rec
			existing.bindingGen = binding.generation
			existing.callbackGen = 0
			existing.callbackUUID = ""
			existing.enqueuedAt = now
			existing.attemptCancel = nil
			continue
		}
		if !s.makeQueueRoomLocked(rec.Priority) {
			continue
		}
		s.jobs[key] = &mdmScheduledJob{
			record: rec, bindingGen: binding.generation, enqueuedAt: now,
		}
	}
	s.mu.Unlock()
}

// refreshReleasedJob reconciles a rebound live job with durable state after the
// prior connection generation releases its claim. Reconnect submission can race
// an in-flight attempt and therefore observe the durable row while it is still
// running. The release is authoritative: copy its preserved retry stage and due
// time into the new generation before redispatching. Never synthesize an
// immediate retry or reuse the stale generation's in-memory state.
func (s *mdmVerificationScheduler) refreshReleasedJob(work mdmSchedulerWork) {
	rec, err := s.store.GetVerificationJob(
		s.ctx, work.job.SEPubKey, work.job.Kind,
	)
	if err != nil {
		if s.ctx.Err() == nil {
			s.server.logger.Error("failed to refresh rebound MDM scheduler job", "error", err)
		}
		return
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	job := s.jobs[work.key]
	if job == nil {
		return
	}
	binding := s.bindings[work.job.SEPubKey]
	if binding == nil {
		if job.bindingGen == work.binding.generation {
			if job.record.UDID != "" && s.byUDID[job.record.UDID] == work.key {
				delete(s.byUDID, job.record.UDID)
			}
			delete(s.jobs, work.key)
		}
		return
	}
	if job.bindingGen != binding.generation ||
		job.bindingGen == work.binding.generation {
		return
	}
	if rec == nil || rec.State == store.VerificationStateCompleted {
		if job.record.UDID != "" && s.byUDID[job.record.UDID] == work.key {
			delete(s.byUDID, job.record.UDID)
		}
		delete(s.jobs, work.key)
		return
	}
	if rec.State == store.VerificationStateRunning {
		// A different coordinator still owns the durable claim. Drop the local
		// copy; the bounded due-row loader will reseed it after claim expiry.
		if job.record.UDID != "" && s.byUDID[job.record.UDID] == work.key {
			delete(s.byUDID, job.record.UDID)
		}
		delete(s.jobs, work.key)
		return
	}
	if oldUDID := job.record.UDID; oldUDID != "" &&
		s.byUDID[oldUDID] == work.key {
		delete(s.byUDID, oldUDID)
	}
	job.record = *rec
	job.running = false
	job.callbackGen = 0
	job.callbackUUID = ""
	job.attemptCancel = nil
	job.enqueuedAt = s.deps.now()
}

func (s *mdmVerificationScheduler) enqueueMDA(binding mdmLiveBinding, udid string) {
	if udid == "" {
		s.metricCounter("mda_verification_total", "outcome", "invalid")
		s.mu.Lock()
		delete(s.bindings, binding.attestation.PublicKey)
		s.mu.Unlock()
		return
	}
	now := s.deps.now().UTC()
	rec, err := s.store.UpsertVerificationJob(s.ctx, store.VerificationJob{
		SEPubKey: binding.attestation.PublicKey, Serial: binding.attestation.SerialNumber,
		UDID: udid, Kind: store.VerificationTaskMDA,
		State: store.VerificationStatePending, Priority: store.VerificationPriorityRefresh,
		NextAttemptAt: now, LastOutcome: store.VerificationOutcomeNone, UpdatedAt: now,
	})
	if err != nil {
		s.server.logger.Error("failed to persist MDA scheduler job", "error", err)
		return
	}
	key := verificationSchedulerKey(rec.SEPubKey, rec.Kind)
	s.mu.Lock()
	live := s.bindings[rec.SEPubKey]
	if live == nil || live.generation != binding.generation {
		s.mu.Unlock()
		return
	}
	live.allowMDA = true
	if existing := s.jobs[key]; existing != nil {
		if existing.record.UDID != "" && s.byUDID[existing.record.UDID] == key {
			delete(s.byUDID, existing.record.UDID)
		}
		existing.record = rec
		existing.bindingGen = binding.generation
		existing.callbackGen = 0
		existing.callbackUUID = ""
		s.mu.Unlock()
		s.metricCounter("mdm_scheduler_deduplicated_total", "state", string(rec.State))
		return
	}
	if !s.makeQueueRoomLocked(rec.Priority) {
		s.mu.Unlock()
		s.metricCounter("mdm_scheduler_queue_rejected_total", "priority", "refresh")
		return
	}
	s.jobs[key] = &mdmScheduledJob{record: rec, bindingGen: binding.generation, enqueuedAt: now}
	s.mu.Unlock()
	s.metricCounter("mdm_scheduler_enqueued_total", "reason", "mda_followup")
	s.signal()
}
