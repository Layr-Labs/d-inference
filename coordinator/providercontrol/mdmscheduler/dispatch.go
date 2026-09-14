package mdmscheduler

import (
	"context"
	"sort"
	"time"

	"github.com/eigeninference/d-inference/coordinator/store"
)

type workItem struct {
	key        string
	job        store.VerificationJob
	binding    Binding
	ctx        context.Context
	cancel     context.CancelFunc
	stopAfter  func() bool
	enqueuedAt time.Time
}

func (s *Scheduler) dispatcher() {
	defer s.wg.Done()
	// lastLoad is wall-clock so the reload cadence holds under test clocks
	// that do not advance; the due-time arithmetic itself stays on deps.Now.
	var lastLoad time.Time
	for {
		if s.shouldLoadDueRows(lastLoad) {
			s.loadDueRows()
			lastLoad = time.Now()
		}
		s.dispatchDueRows()
		s.publishDogStatsDGauges()
		timer := s.deps.NewTimer(s.nextDispatchDelay())
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
// due rows: on the first pass, once per dispatchInterval, and
// whenever the in-memory queue is empty (so newly persisted rows are picked
// up promptly). Retry wakes — a due job that cannot run yet — used to reload
// on every 1 ms pass, which re-scanned the verification table ~34 times a
// second in production and pre-allocated a 4,096-row page each time.
func (s *Scheduler) shouldLoadDueRows(lastLoad time.Time) bool {
	if lastLoad.IsZero() || time.Since(lastLoad) >= dispatchInterval {
		return true
	}
	s.mu.Lock()
	queued := len(s.jobs)
	s.mu.Unlock()
	return queued == 0
}

func (s *Scheduler) nextDispatchDelay() time.Duration {
	now := s.deps.Now()
	delay := dispatchInterval
	s.mu.Lock()
	defer s.mu.Unlock()
	// Same worker arithmetic as dispatchDueRows: the reserved urgent slot is
	// not available to refresh/recovery work, so a due non-urgent job with
	// only that slot free cannot dispatch and must not spin at 1 ms.
	available := s.cfg.Workers
	for _, count := range s.active {
		available -= count
	}
	reservedFree := s.reservedUrgentSlots() - s.activeUrgent
	if reservedFree < 0 {
		reservedFree = 0
	}
	generalAvailable := available - reservedFree
	dueBlocked := false
	for _, job := range s.jobs {
		if job.running || (job.record.State != store.VerificationStatePending && job.record.State != store.VerificationStateBackoff) {
			continue
		}
		candidate := job.record.NextAttemptAt.Sub(now)
		if candidate <= 0 {
			if available > 0 && (isUrgentVerification(job.record) || generalAvailable > 0) {
				return time.Millisecond
			}
			dueBlocked = true
			continue
		}
		if candidate < delay {
			delay = candidate
		}
	}
	// The busy floor is a ceiling on the wake interval, not a replacement for
	// it: a job that becomes due sooner (an urgent one may take the reserved
	// slot) still gets its own timer instead of waiting out the floor.
	if dueBlocked && delay > busyRetryDelay {
		return busyRetryDelay
	}
	return delay
}

func (s *Scheduler) dispatchDueRows() {
	now := s.deps.Now().UTC()
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

func (s *Scheduler) claimAndDispatch(key string, now time.Time) {
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
			s.deps.Logger().Error("failed to claim MDM scheduler job", "error", err)
		}
		return
	}

	s.mu.Lock()
	job = s.jobs[key]
	binding := s.bindings[rec.SEPubKey]
	if job == nil || job.running || binding == nil || binding.generation != job.bindingGen {
		s.mu.Unlock()
		cleanupCtx, cancel := cleanupContext()
		_ = s.store.ReleaseVerificationJob(
			cleanupCtx, rec.SEPubKey, rec.Kind, s.owner, s.deps.Now().UTC(),
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
	work := workItem{
		key: key, job: claimed, binding: *binding,
		ctx: attemptCtx, cancel: cancel, stopAfter: stopAfter,
		enqueuedAt: job.enqueuedAt,
	}
	s.mu.Unlock()
	s.work <- work
}
