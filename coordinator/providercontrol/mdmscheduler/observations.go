package mdmscheduler

import (
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
	key := jobKey(result.PublicKey, store.VerificationTaskSecurityInfo)
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
	record.UpdatedAt = s.deps.Now().UTC()
	updated, err := s.store.UpsertVerificationJob(s.ctx, record)
	if err != nil {
		if s.ctx.Err() == nil {
			s.deps.Logger().Error("failed to persist MDM attempt UDID", "error", err)
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
	key := jobKey(result.PublicKey, kind)
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
	job.callbackGen = binding.generation
	job.callbackUUID = commandUUID
	s.byUDID[udid] = key
}
