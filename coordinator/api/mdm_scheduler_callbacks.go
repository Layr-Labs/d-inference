package api

import (
	"bytes"
	"crypto/sha256"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// ObserveAttemptUDID persists transport identity for the exact running
// SecurityInfo job. It does not authorize late callbacks until the command UUID
// observer below binds the command MicroMDM actually issued.
func (s *mdmVerificationScheduler) ObserveAttemptUDID(provider *registry.Provider, udid string) {
	if s == nil || provider == nil || udid == "" {
		return
	}
	result := provider.GetAttestationResult()
	if result == nil || result.PublicKey == "" {
		return
	}
	key := verificationSchedulerKey(result.PublicKey, store.VerificationTaskSecurityInfo)
	s.mu.Lock()
	job := s.jobs[key]
	binding := s.bindings[result.PublicKey]
	if job == nil || binding == nil || binding.provider != provider ||
		binding.generation != job.bindingGen || !job.running {
		s.mu.Unlock()
		return
	}
	generation := binding.generation
	claimOwner := job.record.ClaimOwner
	record := job.record
	s.mu.Unlock()

	record.UDID = udid
	record.UpdatedAt = s.deps.now().UTC()
	updated, err := s.store.UpsertVerificationJob(s.ctx, record)
	if err != nil {
		if s.ctx.Err() == nil {
			s.server.logger.Error("failed to persist MDM attempt UDID", "error", err)
		}
		return
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	job = s.jobs[key]
	binding = s.bindings[result.PublicKey]
	if job == nil || binding == nil || binding.provider != provider ||
		binding.generation != generation || job.bindingGen != generation ||
		!job.running || job.record.ClaimOwner != claimOwner {
		return
	}
	if oldUDID := job.record.UDID; oldUDID != "" &&
		oldUDID != udid && s.byUDID[oldUDID] == key {
		delete(s.byUDID, oldUDID)
	}
	job.record = updated
	job.callbackGen = 0
	job.callbackUUID = ""
}

func (s *mdmVerificationScheduler) ObserveAttemptCommand(
	provider *registry.Provider,
	kind store.VerificationTaskKind,
	udid, commandUUID string,
) {
	if s == nil || provider == nil || udid == "" || commandUUID == "" {
		return
	}
	result := provider.GetAttestationResult()
	if result == nil || result.PublicKey == "" {
		return
	}
	key := verificationSchedulerKey(result.PublicKey, kind)
	s.mu.Lock()
	defer s.mu.Unlock()
	job := s.jobs[key]
	binding := s.bindings[result.PublicKey]
	if job == nil || binding == nil ||
		binding.provider != provider ||
		binding.generation != job.bindingGen ||
		!binding.challengeSettled ||
		!job.running ||
		job.record.UDID != udid {
		return
	}
	if oldUDID := job.record.UDID; oldUDID != "" &&
		oldUDID != udid && s.byUDID[oldUDID] == key {
		delete(s.byUDID, oldUDID)
	}
	job.callbackGen = binding.generation
	job.callbackUUID = commandUUID
	s.byUDID[udid] = key
}

func (s *mdmVerificationScheduler) ApplyLateSecurityInfo(
	udid, commandUUID string,
	infoSecurityOK bool,
) *mdmLiveBinding {
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

func (s *mdmVerificationScheduler) CompleteLateSecurityInfo(
	binding mdmLiveBinding,
	udid, commandUUID string,
) {
	now := s.deps.now().UTC()
	key := verificationSchedulerKey(binding.attestation.PublicKey, store.VerificationTaskSecurityInfo)
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
	cleanupCtx, cancel := mdmSchedulerCleanupContext()
	_ = s.store.CompleteVerificationJob(
		cleanupCtx, binding.attestation.PublicKey,
		store.VerificationTaskSecurityInfo, owner,
		store.VerificationOutcomeSuccess, now,
	)
	cancel()
	if s.deps.reuseMDA(binding) {
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

func (s *mdmVerificationScheduler) RejectLateSecurityInfo(
	binding mdmLiveBinding,
	udid, commandUUID string,
) {
	now := s.deps.now().UTC()
	key := verificationSchedulerKey(binding.attestation.PublicKey, store.VerificationTaskSecurityInfo)
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
	cleanupCtx, cancel := mdmSchedulerCleanupContext()
	_ = s.store.CompleteVerificationJob(
		cleanupCtx, binding.attestation.PublicKey,
		store.VerificationTaskSecurityInfo, owner,
		store.VerificationOutcomePostureMismatch, now,
	)
	cancel()
	s.signal()
}

// ApplyLateMDA attaches a late Apple response only to the exact scheduler job
// that issued work for this UDID. Unowned and stale-generation callbacks are
// dropped without any fleet-wide fallback.
func (s *Server) ApplyLateMDA(
	udid, commandUUID string,
	certChain [][]byte,
) {
	if s == nil || s.mdmScheduler == nil ||
		udid == "" || commandUUID == "" || len(certChain) == 0 {
		return
	}
	s.mdmScheduler.applyLateMDA(udid, commandUUID, certChain)
}

func (s *mdmVerificationScheduler) applyLateMDA(
	udid, commandUUID string,
	certChain [][]byte,
) bool {
	s.mu.Lock()
	key := s.byUDID[udid]
	job := s.jobs[key]
	if key == "" ||
		job == nil ||
		job.record.Kind != store.VerificationTaskMDA ||
		job.record.UDID != udid {
		s.mu.Unlock()
		return false
	}
	binding := s.bindings[job.record.SEPubKey]
	if binding == nil ||
		binding.generation != job.bindingGen ||
		job.callbackGen != binding.generation ||
		job.callbackUUID != commandUUID ||
		binding.attestation.PublicKey != job.record.SEPubKey ||
		!binding.challengeSettled ||
		!binding.allowMDA {
		s.mu.Unlock()
		return true
	}
	bound := *binding
	owner := job.record.ClaimOwner
	seKey := job.record.SEPubKey
	attemptCancel := job.attemptCancel
	s.mu.Unlock()

	mdaResult, err := attestation.VerifyMDADeviceAttestation(certChain)
	if err != nil || mdaResult == nil || !mdaResult.Valid {
		s.metricCounter("mda_verification_total", "outcome", "invalid")
		return true
	}
	wantFreshness := sha256.Sum256([]byte(bound.attestation.PublicKey))
	if len(mdaResult.FreshnessCode) == 0 ||
		!bytes.Equal(mdaResult.FreshnessCode, wantFreshness[:]) ||
		(mdaResult.DeviceSerial != "" &&
			mdaResult.DeviceSerial != bound.attestation.SerialNumber) ||
		(mdaResult.DeviceUDID != "" && mdaResult.DeviceUDID != udid) {
		s.metricCounter("mda_verification_total", "outcome", "binding_mismatch")
		return true
	}

	s.mu.Lock()
	currentJob := s.jobs[key]
	currentBinding := s.bindings[seKey]
	stillCurrent := currentJob != nil &&
		currentJob.record.Kind == store.VerificationTaskMDA &&
		currentJob.record.UDID == udid &&
		currentJob.bindingGen == bound.generation &&
		currentJob.callbackGen == bound.generation &&
		currentJob.callbackUUID == commandUUID &&
		s.byUDID[udid] == key &&
		currentBinding != nil &&
		currentBinding.generation == bound.generation &&
		currentBinding.provider == bound.provider &&
		currentBinding.challengeSettled &&
		currentBinding.allowMDA
	s.mu.Unlock()
	if !stillCurrent {
		return true
	}
	if !bound.provider.SetMDAProofIfHardwareBound(certChain, mdaResult, true) {
		return true
	}
	if attemptCancel != nil {
		attemptCancel()
	}
	s.server.registry.PersistProvider(bound.provider)
	now := s.deps.now().UTC()
	cleanupCtx, cancel := mdmSchedulerCleanupContext()
	_ = s.store.CompleteVerificationJob(
		cleanupCtx, seKey, store.VerificationTaskMDA,
		owner, store.VerificationOutcomeSuccess, now,
	)
	cancel()
	s.mu.Lock()
	if current := s.jobs[key]; current != nil &&
		current.bindingGen == bound.generation {
		delete(s.jobs, key)
		delete(s.bindings, seKey)
		if s.byUDID[udid] == key {
			delete(s.byUDID, udid)
		}
	}
	s.mu.Unlock()
	s.metricCounter("mda_verification_total", "outcome", "late")
	s.signal()
	return true
}
