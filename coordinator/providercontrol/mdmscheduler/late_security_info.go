package mdmscheduler

import (
	"github.com/eigeninference/d-inference/coordinator/store"
)

func (s *Scheduler) ApplyLateSecurityInfo(
	udid, commandUUID string,
	infoSecurityOK bool,
) *Binding {
	if s == nil || udid == "" || commandUUID == "" {
		return nil
	}
	s.mu.Lock()
	key := s.byUDID[udid]
	job := s.jobs[key]
	if key == "" ||
		job == nil ||
		job.record.Kind != store.VerificationTaskSecurityInfo ||
		job.record.UDID != udid {
		s.mu.Unlock()
		return nil
	}
	binding := s.bindings[job.record.SEPubKey]
	if binding == nil ||
		binding.generation != job.bindingGen ||
		binding.attestation.PublicKey != job.record.SEPubKey ||
		!binding.challengeSettled {
		s.mu.Unlock()
		return nil
	}
	if job.callbackGen != binding.generation ||
		job.callbackUUID != commandUUID {
		s.mu.Unlock()
		return nil
	}
	copy := *binding
	if !infoSecurityOK && job.attemptCancel != nil {
		job.attemptCancel()
	}
	s.mu.Unlock()
	return &copy
}

func (s *Scheduler) CompleteLateSecurityInfo(
	binding Binding,
	udid, commandUUID string,
) {
	now := s.deps.Now().UTC()
	key := jobKey(binding.attestation.PublicKey, store.VerificationTaskSecurityInfo)
	s.mu.Lock()
	job := s.jobs[key]
	currentBinding := s.bindings[binding.attestation.PublicKey]
	if job == nil ||
		job.bindingGen != binding.generation ||
		job.callbackGen != binding.generation ||
		job.callbackUUID != commandUUID ||
		job.record.UDID != udid ||
		s.byUDID[udid] != key ||
		currentBinding == nil ||
		currentBinding.generation != binding.generation ||
		currentBinding.provider != binding.provider ||
		!currentBinding.challengeSettled {
		s.mu.Unlock()
		return
	}
	if job.attemptCancel != nil {
		job.attemptCancel()
	}
	owner := job.record.ClaimOwner
	delete(s.jobs, key)
	if s.byUDID[udid] == key {
		delete(s.byUDID, udid)
	}
	s.mu.Unlock()
	cleanupCtx, cancel := cleanupContext()
	_ = s.store.CompleteVerificationJob(
		cleanupCtx, binding.attestation.PublicKey,
		store.VerificationTaskSecurityInfo, owner,
		store.VerificationOutcomeSuccess, now,
	)
	cancel()
	if s.deps.ReuseMDA(binding.Target()) {
		s.metricCounter("mda_verification_total", "outcome", "reused")
		s.mu.Lock()
		delete(s.bindings, binding.attestation.PublicKey)
		s.mu.Unlock()
	} else {
		s.enqueueMDA(binding, udid)
	}
	s.metricCounter("mdm_scheduler_grants_total", "path", "late")
	s.signal()
}

func (s *Scheduler) RejectLateSecurityInfo(
	binding Binding,
	udid, commandUUID string,
) {
	now := s.deps.Now().UTC()
	key := jobKey(binding.attestation.PublicKey, store.VerificationTaskSecurityInfo)
	s.mu.Lock()
	job := s.jobs[key]
	currentBinding := s.bindings[binding.attestation.PublicKey]
	if job == nil ||
		job.bindingGen != binding.generation ||
		job.callbackGen != binding.generation ||
		job.callbackUUID != commandUUID ||
		job.record.UDID != udid ||
		s.byUDID[udid] != key ||
		currentBinding == nil ||
		currentBinding.generation != binding.generation ||
		currentBinding.provider != binding.provider ||
		!currentBinding.challengeSettled {
		s.mu.Unlock()
		return
	}
	if job.attemptCancel != nil {
		job.attemptCancel()
	}
	owner := job.record.ClaimOwner
	delete(s.jobs, key)
	delete(s.bindings, binding.attestation.PublicKey)
	if s.byUDID[udid] == key {
		delete(s.byUDID, udid)
	}
	s.mu.Unlock()
	cleanupCtx, cancel := cleanupContext()
	_ = s.store.CompleteVerificationJob(
		cleanupCtx, binding.attestation.PublicKey,
		store.VerificationTaskSecurityInfo, owner,
		store.VerificationOutcomePostureMismatch, now,
	)
	cancel()
	s.signal()
}
