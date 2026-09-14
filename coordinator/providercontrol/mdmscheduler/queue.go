package mdmscheduler

import (
	"context"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

type verificationDuePageStore interface {
	ListDueVerificationJobsPage(
		ctx context.Context,
		now time.Time,
		limit, offset int,
	) ([]store.VerificationJob, error)
}

type scheduledJob struct {
	record        store.VerificationJob
	bindingGen    uint64
	callbackGen   uint64
	callbackUUID  string
	enqueuedAt    time.Time
	running       bool
	attemptCancel context.CancelFunc
}

// makeQueueRoomLocked never evicts first/expired or recovery work. An evicted
// refresh remains durable and is reloaded only when bounded memory has room.
func (s *Scheduler) makeQueueRoomLocked(priority store.VerificationPriority) bool {
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

func (s *Scheduler) loadDueRows() {
	now := s.deps.Now().UTC()
	limit := s.cfg.QueueCapacity
	s.mu.Lock()
	offset := s.dueScanOffset
	s.mu.Unlock()

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
			s.deps.Logger().Error("failed to load due MDM scheduler rows", "error", err)
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
		key := jobKey(rec.SEPubKey, rec.Kind)
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
		s.jobs[key] = &scheduledJob{
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
func (s *Scheduler) refreshReleasedJob(work workItem) {
	rec, err := s.store.GetVerificationJob(
		s.ctx, work.job.SEPubKey, work.job.Kind,
	)
	if err != nil {
		if s.ctx.Err() == nil {
			s.deps.Logger().Error("failed to refresh rebound MDM scheduler job", "error", err)
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
	job.enqueuedAt = s.deps.Now()
}

func (s *Scheduler) enqueueMDA(binding Binding, udid string) {
	if udid == "" {
		s.metricCounter("mda_verification_total", "outcome", "invalid")
		s.mu.Lock()
		delete(s.bindings, binding.attestation.PublicKey)
		s.mu.Unlock()
		return
	}
	now := s.deps.Now().UTC()
	rec, err := s.store.UpsertVerificationJob(s.ctx, store.VerificationJob{
		SEPubKey: binding.attestation.PublicKey, Serial: binding.attestation.SerialNumber,
		UDID: udid, Kind: store.VerificationTaskMDA,
		State: store.VerificationStatePending, Priority: store.VerificationPriorityRefresh,
		NextAttemptAt: now, LastOutcome: store.VerificationOutcomeNone, UpdatedAt: now,
	})
	if err != nil {
		s.deps.Logger().Error("failed to persist MDA scheduler job", "error", err)
		return
	}
	key := jobKey(rec.SEPubKey, rec.Kind)
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
	s.jobs[key] = &scheduledJob{record: rec, bindingGen: binding.generation, enqueuedAt: now}
	s.mu.Unlock()
	s.metricCounter("mdm_scheduler_enqueued_total", "reason", "mda_followup")
	s.signal()
}
