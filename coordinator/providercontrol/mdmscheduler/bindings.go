package mdmscheduler

import (
	"context"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// Binding is an opaque receipt for one connection generation. Only the scheduler
// mutates its identity and command state; callers receive a copy.
type Binding struct {
	providerID       string
	provider         *registry.Provider
	attestation      attestation.VerificationResult
	generation       uint64
	ctx              context.Context
	challengeSettled bool
	allowMDA         bool
	// promoteFirstOrExpired marks that this connection's trust-reuse fast-skip
	// DECLINED, so a refresh-classified SecurityInfo job must settle as
	// first/expired (immediate due) — the submit-time hasFreshRecord
	// classification was optimistic and the provider holds no usable trust
	// grant while client requests burn the 120s dispatch-queue deadline.
	promoteFirstOrExpired bool
}

func (s *Scheduler) Submit(ctx context.Context, providerID string, provider *registry.Provider, priority store.VerificationPriority) uint64 {
	if s == nil || provider == nil {
		return 0
	}
	result := provider.GetAttestationResult()
	if result == nil || !result.Valid || result.PublicKey == "" || result.SerialNumber == "" {
		return 0
	}
	s.Start()
	now := s.deps.Now().UTC()
	record, err := s.store.UpsertVerificationJob(ctx, store.VerificationJob{
		SEPubKey: result.PublicKey, Serial: result.SerialNumber,
		Kind:     store.VerificationTaskSecurityInfo,
		State:    store.VerificationStateWaitingChallenge,
		Priority: priority, LastOutcome: store.VerificationOutcomeNone,
		UpdatedAt: now,
	})
	if err != nil {
		s.deps.Logger().Error("failed to persist MDM scheduler submission", "error", err)
		s.metricCounter("mdm_scheduler_queue_rejected_total", "priority", schedulerPriorityLabel(priority))
		return 0
	}

	seKey := result.PublicKey
	key := jobKey(seKey, record.Kind)
	s.mu.Lock()
	generation := s.generation.Add(1)
	binding := &Binding{
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
	s.jobs[key] = &scheduledJob{record: record, bindingGen: generation, enqueuedAt: now}
	s.mu.Unlock()
	s.metricCounter("mdm_scheduler_enqueued_total", "reason", "registration")
	s.signal()
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
	if binding := s.bindings[result.PublicKey]; binding != nil && binding.provider == provider {
		binding.promoteFirstOrExpired = true
	}
	s.mu.Unlock()
}

func (s *Scheduler) Unbind(seKey string, generation uint64) {
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

// Target returns a copy of this receipt's provider identity and evidence.
func (b Binding) Target() Target {
	return Target{ProviderID: b.providerID, Provider: b.provider, Attestation: b.attestation}
}
