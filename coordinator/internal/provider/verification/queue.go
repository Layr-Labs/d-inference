package verification

import (
	"context"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"time"
)

func (s *Scheduler) Submit(ctx context.Context, providerID string, provider *registry.Provider, priority store.VerificationPriority) uint64 {
	return s.submit(ctx, providerID, provider, priority, nil)
}

func (s *Scheduler) submit(ctx context.Context, providerID string, provider *registry.Provider, priority store.VerificationPriority, start func()) uint64 {
	if s == nil || provider == nil {
		return 0
	}
	if s.deps.LegacyMDMAllowed != nil && !s.deps.LegacyMDMAllowed(provider) {
		provider.SetMDMFailureReason("app-attest-required")
		return 0
	}
	result := provider.GetAttestationResult()
	if result == nil || !result.Valid || result.PublicKey == "" || result.SerialNumber == "" {
		return 0
	}
	if start != nil {
		start()
	}
	now := s.deps.Now().UTC()
	record, err := s.store.UpsertVerificationJob(ctx, store.VerificationJob{
		SEPubKey: result.PublicKey, Serial: result.SerialNumber,
		Kind:     store.VerificationTaskSecurityInfo,
		State:    store.VerificationStateWaitingChallenge,
		Priority: priority, LastOutcome: store.VerificationOutcomeNone,
		UpdatedAt: now,
	})
	if err != nil {
		s.logger.Error("failed to persist MDM scheduler submission", "error", err)
		s.metricCounter("mdm_scheduler_queue_rejected_total", "priority", schedulerPriorityLabel(priority))
		return 0
	}

	seKey := result.PublicKey
	key := Key(seKey, record.Kind)
	s.mu.Lock()
	generation := s.generation.Add(1)
	binding := &Binding{
		ProviderID: providerID, Provider: provider, Attestation: *result,
		Generation: generation, Context: ctx,
	}
	s.bindings[seKey] = binding
	for otherKey, other := range s.jobs {
		if other.Record.SEPubKey != seKey || other.Record.Kind != store.VerificationTaskMDA {
			continue
		}
		if other.AttemptCancel != nil {
			other.AttemptCancel()
		}
		if other.Record.UDID != "" && s.byUDID[other.Record.UDID] == otherKey {
			delete(s.byUDID, other.Record.UDID)
		}
		delete(s.jobs, otherKey)
	}
	if existing := s.jobs[key]; existing != nil {
		if existing.AttemptCancel != nil {
			existing.AttemptCancel()
		}
		if existing.Record.UDID != "" && s.byUDID[existing.Record.UDID] == key {
			delete(s.byUDID, existing.Record.UDID)
		}
		existing.Record = record
		existing.BindingGen = generation
		existing.CallbackGen = 0
		existing.CallbackUUID = ""
		existing.EnqueuedAt = now
		s.mu.Unlock()
		s.metricCounter("mdm_scheduler_deduplicated_total", "state", string(record.State))
		s.Wake()
		return generation
	}
	if record.State == store.VerificationStateRunning &&
		record.ClaimOwner != "" && record.ClaimOwner != s.owner {
		s.mu.Unlock()
		s.metricCounter("mdm_scheduler_deduplicated_total", "state", string(record.State))
		s.Wake()
		return generation
	}
	if !s.makeQueueRoomLocked(priority) {
		s.mu.Unlock()
		s.metricCounter("mdm_scheduler_queue_rejected_total", "priority", schedulerPriorityLabel(priority))
		s.Wake()
		return generation
	}
	s.jobs[key] = &scheduledJob{Record: record, BindingGen: generation, EnqueuedAt: now}
	s.mu.Unlock()
	s.metricCounter("mdm_scheduler_enqueued_total", "reason", "registration")
	s.Wake()
	return generation
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
func (s *Scheduler) PromoteFailedFastSkip(provider *registry.Provider) {
	if s == nil || provider == nil {
		return
	}
	result := provider.GetAttestationResult()
	if result == nil || result.PublicKey == "" {
		return
	}
	s.mu.Lock()
	if binding := s.bindings[result.PublicKey]; binding != nil && binding.Provider == provider {
		binding.PromoteFirstOrExpired = true
	}
	s.mu.Unlock()
}

// ChallengeSettled gates all SecurityInfo work on the current connection's
// phase-1 challenge. A fast-skip completes the durable row before any worker or
// MDM command is consumed.
func (s *Scheduler) ChallengeSettled(provider *registry.Provider, fastSkip bool) {
	if s == nil || provider == nil {
		return
	}
	result := provider.GetAttestationResult()
	if result == nil || result.PublicKey == "" {
		return
	}
	seKey := result.PublicKey
	key := Key(seKey, store.VerificationTaskSecurityInfo)
	now := s.deps.Now().UTC()
	if fastSkip {
		s.mu.Lock()
		binding := s.bindings[seKey]
		job := s.jobs[key]
		if binding == nil || binding.Provider != provider {
			s.mu.Unlock()
			return
		}
		owner := ""
		if job != nil {
			owner = job.Record.ClaimOwner
			if job.AttemptCancel != nil {
				job.AttemptCancel()
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
			s.logger.Error("failed to complete fast-skip scheduler job", "error", err)
		}
		s.metricCounter("mdm_scheduler_cancelled_total", "reason", "fast_skip")
		s.metricCounter("mdm_scheduler_grants_total", "path", "reuse")
		s.Wake()
		return
	}

	s.mu.Lock()
	binding := s.bindings[seKey]
	if binding == nil || binding.Provider != provider {
		s.mu.Unlock()
		return
	}
	binding.ChallengeSettled = true
	promote := binding.PromoteFirstOrExpired
	generation := binding.Generation
	job := s.jobs[key]
	var record *store.VerificationJob
	if job != nil {
		copy := job.Record
		record = &copy
	}
	s.mu.Unlock()

	if record == nil {
		durable, err := s.store.GetVerificationJob(s.ctx, seKey, store.VerificationTaskSecurityInfo)
		if err != nil {
			s.logger.Error("failed to load queue-rejected MDM scheduler job", "error", err)
			return
		}
		if durable == nil {
			s.Wake()
			return
		}
		record = durable
	}

	s.mu.Lock()
	currentBinding := s.bindings[seKey]
	stillCurrent := currentBinding != nil &&
		currentBinding.Provider == provider &&
		currentBinding.Generation == generation &&
		currentBinding.ChallengeSettled
	s.mu.Unlock()
	if !stillCurrent {
		return
	}

	previous := *record
	if promote && record.Priority == store.VerificationPriorityRefresh {
		record.Priority = store.VerificationPriorityFirstOrExpired
	}
	record.State = store.VerificationStatePending
	record.NextAttemptAt = now.Add(s.initialSpread(record.Priority))
	record.UpdatedAt = now
	updated, err := s.store.UpsertVerificationJob(s.ctx, *record)
	if err != nil {
		s.logger.Error("failed to make MDM scheduler job eligible", "error", err)
		return
	}
	for {
		s.mu.Lock()
		current := s.jobs[key]
		if current == nil || current.BindingGen != generation {
			s.mu.Unlock()
			break
		}
		if current.Record == previous {
			current.Record = updated
			s.mu.Unlock()
			break
		}
		// A worker changed the record while the store call was in flight.
		// Re-read instead of reviving a released claim or losing a promotion
		// persisted after that release. Never hold mu over store I/O.
		previous = current.Record
		s.mu.Unlock()
		durable, err := s.store.GetVerificationJob(s.ctx, seKey, store.VerificationTaskSecurityInfo)
		if err != nil {
			s.logger.Error("failed to reconcile settled MDM scheduler job", "error", err)
			break
		}
		if durable == nil {
			break
		}
		updated = *durable
	}
	s.Wake()
}

// initialSpread is the delay before the first attempt once the phase-1
// challenge settles. First/expired work backs a provider with no usable trust
// grant — client requests routed to it queue against the 120s dispatch
// deadline — so it becomes due essentially immediately, with at most a tiny
// jitter (never past mdmFirstVerifySpreadMax) to de-synchronise mass expiry.
// Refresh and recovery work still holds a valid grant and keeps the full
// configured spread so routine releases and coordinator restarts never
// stampede MDM.
func (s *Scheduler) initialSpread(priority store.VerificationPriority) time.Duration {
	if priority == store.VerificationPriorityFirstOrExpired {
		return s.deps.Jitter(0, min(s.config.InitialSpreadMax, mdmFirstVerifySpreadMax))
	}
	return s.deps.Jitter(s.config.InitialSpreadMin, s.config.InitialSpreadMax)
}

func (s *Scheduler) Unbind(seKey string, generation uint64) {
	if s == nil || seKey == "" || generation == 0 {
		return
	}
	s.mu.Lock()
	binding := s.bindings[seKey]
	if binding == nil || binding.Generation != generation {
		s.mu.Unlock()
		return
	}
	delete(s.bindings, seKey)
	for key, job := range s.jobs {
		if job.Record.SEPubKey != seKey || job.BindingGen != generation {
			continue
		}
		if job.AttemptCancel != nil {
			job.AttemptCancel()
		}
		if job.Record.UDID != "" && s.byUDID[job.Record.UDID] == key {
			delete(s.byUDID, job.Record.UDID)
		}
		if !job.Running {
			delete(s.jobs, key)
		}
	}
	s.mu.Unlock()
	s.metricCounter("mdm_scheduler_cancelled_total", "reason", "disconnect")
	s.Wake()
}

// Forget drops the in-memory jobs, bindings and UDID routes of erased SE
// keys and cancels their running attempts. A canceled attempt only releases
// its claim, which is an UPDATE of a row the scrub already deleted.
func (s *Scheduler) Forget(seKeys []string) {
	if s == nil || len(seKeys) == 0 {
		return
	}
	erased := make(map[string]bool, len(seKeys))
	for _, key := range seKeys {
		erased[key] = true
	}
	s.mu.Lock()
	for key, job := range s.jobs {
		if !erased[job.Record.SEPubKey] {
			continue
		}
		if job.AttemptCancel != nil {
			job.AttemptCancel()
		}
		if job.Record.UDID != "" && s.byUDID[job.Record.UDID] == key {
			delete(s.byUDID, job.Record.UDID)
		}
		if !job.Running {
			delete(s.jobs, key)
		}
	}
	for key := range erased {
		delete(s.bindings, key)
	}
	s.mu.Unlock()
	s.Wake()
}

func (s *Scheduler) LoadDueRows() {
	now := s.deps.Now().UTC()
	limit := s.config.QueueCapacity
	offset := s.DueScanCursor()

	var (
		rows []store.VerificationJob
		err  error
	)
	if paged, ok := store.As[verificationDuePageStore](s.store); ok {
		rows, err = paged.ListDueVerificationJobsPage(
			s.ctx, now, limit, offset,
		)
	} else {
		rows, err = s.store.ListDueVerificationJobs(s.ctx, now, limit)
		offset = 0
	}
	if err != nil {
		if s.ctx.Err() == nil {
			s.logger.Error("failed to load due MDM scheduler rows", "error", err)
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
		key := Key(rec.SEPubKey, rec.Kind)
		binding := s.bindings[rec.SEPubKey]
		if binding == nil ||
			(rec.Kind == store.VerificationTaskSecurityInfo && !binding.ChallengeSettled) ||
			(rec.Kind == store.VerificationTaskMDA && (!binding.ChallengeSettled || !binding.AllowMDA)) {
			continue
		}
		if existing := s.jobs[key]; existing != nil {
			claimExpired := rec.State == store.VerificationStateRunning &&
				rec.ClaimExpiresAt != nil && !rec.ClaimExpiresAt.After(now)
			stalePlaceholder := !existing.Running &&
				rec.ClaimOwner != s.owner &&
				claimExpired
			if !stalePlaceholder {
				continue
			}
			if oldUDID := existing.Record.UDID; oldUDID != "" &&
				s.byUDID[oldUDID] == key {
				delete(s.byUDID, oldUDID)
			}
			existing.Record = rec
			existing.BindingGen = binding.Generation
			existing.CallbackGen = 0
			existing.CallbackUUID = ""
			existing.EnqueuedAt = now
			existing.AttemptCancel = nil
			continue
		}
		if !s.makeQueueRoomLocked(rec.Priority) {
			continue
		}
		s.jobs[key] = &scheduledJob{
			Record: rec, BindingGen: binding.Generation, EnqueuedAt: now,
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
func (s *Scheduler) refreshReleasedJob(work mdmSchedulerWork) {
	rec, err := s.store.GetVerificationJob(
		s.ctx, work.job.SEPubKey, work.job.Kind,
	)
	if err != nil {
		if s.ctx.Err() == nil {
			s.logger.Error("failed to refresh rebound MDM scheduler job", "error", err)
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
		if job.BindingGen == work.binding.Generation {
			if job.Record.UDID != "" && s.byUDID[job.Record.UDID] == work.key {
				delete(s.byUDID, job.Record.UDID)
			}
			delete(s.jobs, work.key)
		}
		return
	}
	if job.BindingGen != binding.Generation ||
		job.BindingGen == work.binding.Generation {
		return
	}
	if rec == nil || rec.State == store.VerificationStateCompleted {
		if job.Record.UDID != "" && s.byUDID[job.Record.UDID] == work.key {
			delete(s.byUDID, job.Record.UDID)
		}
		delete(s.jobs, work.key)
		return
	}
	if rec.State == store.VerificationStateRunning {
		// A different coordinator still owns the durable claim. Drop the local
		// copy; the bounded due-row loader will reseed it after claim expiry.
		if job.Record.UDID != "" && s.byUDID[job.Record.UDID] == work.key {
			delete(s.byUDID, job.Record.UDID)
		}
		delete(s.jobs, work.key)
		return
	}
	if oldUDID := job.Record.UDID; oldUDID != "" &&
		s.byUDID[oldUDID] == work.key {
		delete(s.byUDID, oldUDID)
	}
	job.Record = *rec
	job.Running = false
	job.CallbackGen = 0
	job.CallbackUUID = ""
	job.AttemptCancel = nil
	job.EnqueuedAt = s.deps.Now()
}

func (s *Scheduler) EnqueueMDA(binding Binding, udid string) {
	if s.deps.LegacyMDMAllowed != nil && !s.deps.LegacyMDMAllowed(binding.Provider) {
		return
	}
	if udid == "" {
		s.metricCounter("mda_verification_total", "outcome", "invalid")
		s.mu.Lock()
		delete(s.bindings, binding.Attestation.PublicKey)
		s.mu.Unlock()
		return
	}
	now := s.deps.Now().UTC()
	rec, err := s.store.UpsertVerificationJob(s.ctx, store.VerificationJob{
		SEPubKey: binding.Attestation.PublicKey, Serial: binding.Attestation.SerialNumber,
		UDID: udid, Kind: store.VerificationTaskMDA,
		State: store.VerificationStatePending, Priority: store.VerificationPriorityRefresh,
		NextAttemptAt: now, LastOutcome: store.VerificationOutcomeNone, UpdatedAt: now,
	})
	if err != nil {
		s.logger.Error("failed to persist MDA scheduler job", "error", err)
		return
	}
	key := Key(rec.SEPubKey, rec.Kind)
	s.mu.Lock()
	live := s.bindings[rec.SEPubKey]
	if live == nil || live.Generation != binding.Generation {
		s.mu.Unlock()
		return
	}
	live.AllowMDA = true
	if existing := s.jobs[key]; existing != nil {
		if existing.Record.UDID != "" && s.byUDID[existing.Record.UDID] == key {
			delete(s.byUDID, existing.Record.UDID)
		}
		existing.Record = rec
		existing.BindingGen = binding.Generation
		existing.CallbackGen = 0
		existing.CallbackUUID = ""
		s.mu.Unlock()
		s.metricCounter("mdm_scheduler_deduplicated_total", "state", string(rec.State))
		return
	}
	if !s.makeQueueRoomLocked(rec.Priority) {
		s.mu.Unlock()
		s.metricCounter("mdm_scheduler_queue_rejected_total", "priority", "refresh")
		return
	}
	s.jobs[key] = &scheduledJob{Record: rec, BindingGen: binding.Generation, EnqueuedAt: now}
	s.mu.Unlock()
	s.metricCounter("mdm_scheduler_enqueued_total", "reason", "mda_followup")
	s.Wake()
}
