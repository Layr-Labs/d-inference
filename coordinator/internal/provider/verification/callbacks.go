package verification

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
func (s *Scheduler) ObserveAttemptUDID(provider *registry.Provider, udid string) {
	if s == nil || provider == nil || udid == "" {
		return
	}
	result := provider.GetAttestationResult()
	if result == nil || result.PublicKey == "" {
		return
	}
	key := Key(result.PublicKey, store.VerificationTaskSecurityInfo)
	s.mu.Lock()
	job := s.jobs[key]
	binding := s.bindings[result.PublicKey]
	if job == nil || binding == nil || binding.Provider != provider ||
		binding.Generation != job.BindingGen || !job.Running {
		s.mu.Unlock()
		return
	}
	generation := binding.Generation
	claimOwner := job.Record.ClaimOwner
	record := job.Record
	s.mu.Unlock()

	record.UDID = udid
	record.UpdatedAt = s.deps.Now().UTC()
	updated, err := s.store.UpsertVerificationJob(s.ctx, record)
	if err != nil {
		if s.ctx.Err() == nil {
			s.logger.Error("failed to persist MDM attempt UDID", "error", err)
		}
		return
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	job = s.jobs[key]
	binding = s.bindings[result.PublicKey]
	if job == nil || binding == nil || binding.Provider != provider ||
		binding.Generation != generation || job.BindingGen != generation ||
		!job.Running || job.Record.ClaimOwner != claimOwner {
		return
	}
	if oldUDID := job.Record.UDID; oldUDID != "" &&
		oldUDID != udid && s.byUDID[oldUDID] == key {
		delete(s.byUDID, oldUDID)
	}
	job.Record = updated
	job.CallbackGen = 0
	job.CallbackUUID = ""
}

func (s *Scheduler) ObserveAttemptCommand(
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
	key := Key(result.PublicKey, kind)
	s.mu.Lock()
	defer s.mu.Unlock()
	job := s.jobs[key]
	binding := s.bindings[result.PublicKey]
	if job == nil || binding == nil ||
		binding.Provider != provider ||
		binding.Generation != job.BindingGen ||
		!binding.ChallengeSettled ||
		!job.Running ||
		job.Record.UDID != udid {
		return
	}
	if oldUDID := job.Record.UDID; oldUDID != "" &&
		oldUDID != udid && s.byUDID[oldUDID] == key {
		delete(s.byUDID, oldUDID)
	}
	job.CallbackGen = binding.Generation
	job.CallbackUUID = commandUUID
	s.byUDID[udid] = key
}

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
		job.Record.Kind != store.VerificationTaskSecurityInfo ||
		job.Record.UDID != udid {
		s.mu.Unlock()
		return nil
	}
	binding := s.bindings[job.Record.SEPubKey]
	if binding == nil ||
		binding.Generation != job.BindingGen ||
		binding.Attestation.PublicKey != job.Record.SEPubKey ||
		!binding.ChallengeSettled {
		s.mu.Unlock()
		return nil
	}
	if job.CallbackGen != binding.Generation ||
		job.CallbackUUID != commandUUID {
		s.mu.Unlock()
		return nil
	}
	copy := *binding
	if !infoSecurityOK && job.AttemptCancel != nil {
		job.AttemptCancel()
	}
	s.mu.Unlock()
	return &copy
}

func (s *Scheduler) CompleteLateSecurityInfo(
	binding Binding,
	udid, commandUUID string,
) {
	now := s.deps.Now().UTC()
	key := Key(binding.Attestation.PublicKey, store.VerificationTaskSecurityInfo)
	s.mu.Lock()
	job := s.jobs[key]
	currentBinding := s.bindings[binding.Attestation.PublicKey]
	if job == nil ||
		job.BindingGen != binding.Generation ||
		job.CallbackGen != binding.Generation ||
		job.CallbackUUID != commandUUID ||
		job.Record.UDID != udid ||
		s.byUDID[udid] != key ||
		currentBinding == nil ||
		currentBinding.Generation != binding.Generation ||
		currentBinding.Provider != binding.Provider ||
		!currentBinding.ChallengeSettled {
		s.mu.Unlock()
		return
	}
	if job.AttemptCancel != nil {
		job.AttemptCancel()
	}
	owner := job.Record.ClaimOwner
	delete(s.jobs, key)
	if s.byUDID[udid] == key {
		delete(s.byUDID, udid)
	}
	s.mu.Unlock()
	cleanupCtx, cancel := mdmSchedulerCleanupContext()
	_ = s.store.CompleteVerificationJob(
		cleanupCtx, binding.Attestation.PublicKey,
		store.VerificationTaskSecurityInfo, owner,
		store.VerificationOutcomeSuccess, now,
	)
	cancel()
	if s.deps.ReuseMDA(binding) {
		s.metricCounter("mda_verification_total", "outcome", "reused")
		s.mu.Lock()
		delete(s.bindings, binding.Attestation.PublicKey)
		s.mu.Unlock()
	} else {
		s.EnqueueMDA(binding, udid)
	}
	s.metricCounter("mdm_scheduler_grants_total", "path", "late")
	s.Wake()
}

func (s *Scheduler) RejectLateSecurityInfo(
	binding Binding,
	udid, commandUUID string,
) {
	now := s.deps.Now().UTC()
	key := Key(binding.Attestation.PublicKey, store.VerificationTaskSecurityInfo)
	s.mu.Lock()
	job := s.jobs[key]
	currentBinding := s.bindings[binding.Attestation.PublicKey]
	if job == nil ||
		job.BindingGen != binding.Generation ||
		job.CallbackGen != binding.Generation ||
		job.CallbackUUID != commandUUID ||
		job.Record.UDID != udid ||
		s.byUDID[udid] != key ||
		currentBinding == nil ||
		currentBinding.Generation != binding.Generation ||
		currentBinding.Provider != binding.Provider ||
		!currentBinding.ChallengeSettled {
		s.mu.Unlock()
		return
	}
	if job.AttemptCancel != nil {
		job.AttemptCancel()
	}
	owner := job.Record.ClaimOwner
	delete(s.jobs, key)
	delete(s.bindings, binding.Attestation.PublicKey)
	if s.byUDID[udid] == key {
		delete(s.byUDID, udid)
	}
	s.mu.Unlock()
	cleanupCtx, cancel := mdmSchedulerCleanupContext()
	_ = s.store.CompleteVerificationJob(
		cleanupCtx, binding.Attestation.PublicKey,
		store.VerificationTaskSecurityInfo, owner,
		store.VerificationOutcomePostureMismatch, now,
	)
	cancel()
	s.Wake()
}

func (s *Scheduler) ApplyLateMDA(
	udid, commandUUID string,
	certChain [][]byte,
) bool {
	s.mu.Lock()
	key := s.byUDID[udid]
	job := s.jobs[key]
	if key == "" ||
		job == nil ||
		job.Record.Kind != store.VerificationTaskMDA ||
		job.Record.UDID != udid {
		s.mu.Unlock()
		return false
	}
	binding := s.bindings[job.Record.SEPubKey]
	if binding == nil {
		s.mu.Unlock()
		return true
	}
	resolved, consumed := ResolveMDACallback(job.Record, *binding, job.BindingGen, job.CallbackGen, job.CallbackUUID, udid, commandUUID)
	if resolved == nil {
		s.mu.Unlock()
		return consumed
	}
	bound := *resolved
	owner := job.Record.ClaimOwner
	seKey := job.Record.SEPubKey
	attemptCancel := job.AttemptCancel
	s.mu.Unlock()

	mdaResult, err := attestation.VerifyMDADeviceAttestation(certChain)
	if err != nil || mdaResult == nil || !mdaResult.Valid {
		s.metricCounter("mda_verification_total", "outcome", "invalid")
		return true
	}
	wantFreshness := sha256.Sum256([]byte(bound.Attestation.PublicKey))
	if len(mdaResult.FreshnessCode) == 0 ||
		!bytes.Equal(mdaResult.FreshnessCode, wantFreshness[:]) ||
		(mdaResult.DeviceSerial != "" &&
			mdaResult.DeviceSerial != bound.Attestation.SerialNumber) ||
		(mdaResult.DeviceUDID != "" && mdaResult.DeviceUDID != udid) {
		s.metricCounter("mda_verification_total", "outcome", "binding_mismatch")
		return true
	}

	s.mu.Lock()
	currentJob := s.jobs[key]
	currentBinding := s.bindings[seKey]
	stillCurrent := currentJob != nil &&
		currentJob.Record.Kind == store.VerificationTaskMDA &&
		currentJob.Record.UDID == udid &&
		currentJob.BindingGen == bound.Generation &&
		currentJob.CallbackGen == bound.Generation &&
		currentJob.CallbackUUID == commandUUID &&
		s.byUDID[udid] == key &&
		currentBinding != nil &&
		currentBinding.Generation == bound.Generation &&
		currentBinding.Provider == bound.Provider &&
		currentBinding.ChallengeSettled &&
		currentBinding.AllowMDA
	s.mu.Unlock()
	if !stillCurrent {
		return true
	}
	if !bound.Provider.SetMDAProofIfHardwareBound(certChain, mdaResult, true) {
		return true
	}
	if attemptCancel != nil {
		attemptCancel()
	}
	s.deps.PersistProvider(bound.Provider)
	now := s.deps.Now().UTC()
	cleanupCtx, cancel := mdmSchedulerCleanupContext()
	_ = s.store.CompleteVerificationJob(
		cleanupCtx, seKey, store.VerificationTaskMDA,
		owner, store.VerificationOutcomeSuccess, now,
	)
	cancel()
	s.mu.Lock()
	if current := s.jobs[key]; current != nil &&
		current.BindingGen == bound.Generation {
		delete(s.jobs, key)
		delete(s.bindings, seKey)
		if s.byUDID[udid] == key {
			delete(s.byUDID, udid)
		}
	}
	s.mu.Unlock()
	s.metricCounter("mda_verification_total", "outcome", "late")
	s.Wake()
	return true
}
