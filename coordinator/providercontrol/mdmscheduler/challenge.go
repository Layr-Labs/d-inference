package mdmscheduler

import (
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

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
	key := jobKey(seKey, store.VerificationTaskSecurityInfo)
	now := s.deps.Now().UTC()
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
		cleanupCtx, cancel := cleanupContext()
		err := s.store.CompleteVerificationJob(
			cleanupCtx, seKey, store.VerificationTaskSecurityInfo, owner,
			store.VerificationOutcomeReused, now,
		)
		cancel()
		if err != nil {
			s.deps.Logger().Error("failed to complete fast-skip scheduler job", "error", err)
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
			s.deps.Logger().Error("failed to load queue-rejected MDM scheduler job", "error", err)
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
		s.deps.Logger().Error("failed to make MDM scheduler job eligible", "error", err)
		return
	}
	s.mu.Lock()
	if current := s.jobs[key]; current != nil && current.bindingGen == generation {
		current.record = updated
	}
	s.mu.Unlock()
	s.signal()
}
