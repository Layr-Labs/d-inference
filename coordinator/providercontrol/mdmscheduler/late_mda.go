package mdmscheduler

import (
	"bytes"
	"crypto/sha256"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func (s *Scheduler) ApplyLateMDA(
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
	s.deps.Registry().PersistProvider(bound.provider)
	now := s.deps.Now().UTC()
	cleanupCtx, cancel := cleanupContext()
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
