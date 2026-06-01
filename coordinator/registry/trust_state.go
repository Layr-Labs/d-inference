package registry

import (
	"time"
)

// MarkUntrusted sets a provider's status to untrusted for a hard/security
// reason (bad encrypted chunk, MDM/MDA failure, SIP disabled, binary or model
// hash mismatch, serial impersonation, attestation failure). The deroute is
// non-recoverable: the provider stays untrusted until it reconnects and
// re-registers. This is the default for every direct deroute call site.
func (r *Registry) MarkUntrusted(providerID string) {
	r.markUntrusted(providerID, false)
}

// MarkUntrustedTransient sets a provider's status to untrusted for a *transient*
// reason — MaxFailedChallenges consecutive missed-challenge timeouts (screen
// sleep, network blip, momentary Secure Enclave inaccessibility). Unlike
// MarkUntrusted, the provider remains eligible to self-recover: the challenge
// loop keeps challenging it (see ChallengeShouldStop), and a subsequent fully
// passing challenge (RecordChallengeSuccess) restores it to online.
//
// A passing challenge re-verifies signature, SIP, secure boot, binary hash,
// model hash and runtime before RecordChallengeSuccess is reached, so using it
// as the recovery trigger is safe.
func (r *Registry) MarkUntrustedTransient(providerID string) {
	r.markUntrusted(providerID, true)
}

// markUntrusted is the shared implementation. recoverable=true marks the untrust
// as transiently recoverable; recoverable=false is a hard deroute.
//
// Transition rules:
//   - not untrusted -> untrusted: decrement online/model counts, set status and
//     the recoverable flag.
//   - already untrusted + hard (recoverable=false): clear the flag. A hard
//     reason always overrides/downgrades a previously-recoverable untrust.
//   - already untrusted + transient (recoverable=true): leave the flag as-is, so
//     a transient timeout can never *upgrade* a hard deroute to recoverable
//     (matters for an in-flight challenge timeout that races a hard deroute).
func (r *Registry) markUntrusted(providerID string, recoverable bool) {
	r.mu.Lock()
	p, ok := r.providers[providerID]
	if !ok {
		r.mu.Unlock()
		return
	}

	p.mu.Lock()
	if p.Status != StatusUntrusted {
		r.onlineCount.Add(-1)
		for _, m := range p.Models {
			r.modelProviderDec(m.ID)
		}
		p.Status = StatusUntrusted
		p.untrustedRecoverable = recoverable
	} else if !recoverable {
		p.untrustedRecoverable = false
	}
	failed := p.FailedChallenges // read under p.mu (the old code read this unlocked)
	p.mu.Unlock()
	r.mu.Unlock()

	r.logger.Warn("provider marked as untrusted",
		"provider_id", providerID,
		"failed_challenges", failed,
		"recoverable", recoverable,
	)
}

// SetTrustLevel updates a provider's trust level (thread-safe).
func (r *Registry) SetTrustLevel(providerID string, level TrustLevel) {
	r.mu.RLock()
	p, ok := r.providers[providerID]
	r.mu.RUnlock()
	if !ok {
		return
	}
	p.mu.Lock()
	p.TrustLevel = level
	p.mu.Unlock()

	// Persist trust state.
	r.persistProviderNow(p)
}

// RecordChallengeSuccess records a successful challenge-response verification.
// A fully passing challenge re-verifies signature, SIP, secure boot, binary
// hash, model hash and runtime (see verifyChallengeResponse) before this is
// called, so it doubles as the recovery trigger for a *transiently* untrusted
// provider.
//
// Returns true iff this call recovered a transiently-untrusted provider back to
// online. The caller (verifyChallengeResponse) uses that to push a fresh
// "online" trust_status so the provider clears its local untrusted state and
// cancels the pending diagnostic auto-report it scheduled at deroute time.
func (r *Registry) RecordChallengeSuccess(providerID string) bool {
	r.mu.RLock()
	p, ok := r.providers[providerID]
	r.mu.RUnlock()
	if !ok {
		return false
	}

	recovered := r.recoverIfTransientlyUntrusted(providerID, p)

	p.mu.Lock()
	p.LastChallengeVerified = time.Now()
	p.FailedChallenges = 0
	if !p.ChallengeVerifiedSIP {
		p.ChallengeVerifiedSIP = true
	}
	p.Reputation.RecordChallengePass()
	p.mu.Unlock()

	// Persist challenge state and reputation.
	r.persistProviderNow(p)
	r.persistReputation(p)

	if recovered {
		r.logger.Info("provider recovered from transient deroute", "provider_id", providerID)
	}

	// A newly verified (or newly recovered) provider may unlock queued requests
	// for any model it serves.
	r.drainQueuedRequestsForModels(providerModelIDs(p))

	return recovered
}

// recoverIfTransientlyUntrusted promotes a transiently-untrusted provider back
// to online, mirroring markUntrusted's bookkeeping in reverse. Returns true iff
// a transition occurred. It acquires r.mu (write) then p.mu — the same order as
// markUntrusted/Register/Disconnect — so online/model counts stay consistent and
// the path is deadlock-free.
func (r *Registry) recoverIfTransientlyUntrusted(providerID string, p *Provider) bool {
	// Cheap pre-check under p.mu only, so the common (non-recovery) success path
	// never contends on the registry write lock.
	p.mu.Lock()
	eligible := p.Status == StatusUntrusted && p.untrustedRecoverable
	p.mu.Unlock()
	if !eligible {
		return false
	}

	r.mu.Lock()
	// Re-verify membership: RecordChallengeSuccess looked p up under RLock and
	// released it, so Disconnect may have removed (or replaced) it since. A
	// transiently-untrusted provider was already decremented out of the counts,
	// and Disconnect does not decrement an untrusted provider, so incrementing a
	// stale/removed pointer here would permanently corrupt onlineCount and
	// modelProviders. Only recover the provider still registered under this ID.
	if cur, ok := r.providers[providerID]; !ok || cur != p {
		r.mu.Unlock()
		return false
	}
	p.mu.Lock()
	// Re-check under the write lock: a hard deroute may have intervened and
	// cleared the recoverable flag between the pre-check and here.
	if p.Status != StatusUntrusted || !p.untrustedRecoverable {
		p.mu.Unlock()
		r.mu.Unlock()
		return false
	}
	r.onlineCount.Add(1)
	for _, m := range p.Models {
		r.modelProviderInc(m.ID)
	}
	p.Status = StatusOnline
	p.untrustedRecoverable = false
	p.mu.Unlock()
	r.mu.Unlock()
	return true
}

// RecordChallengeFailure records a failed challenge-response. Returns the
// new consecutive failure count.
//
// When transientOnly is true (timeout — the provider didn't respond in time),
// routing eligibility is preserved until MaxFailedChallenges consecutive
// failures. A single transient timeout should not instantly deroute a provider
// that was verified seconds ago.
//
// When transientOnly is false (security failure — wrong signature, SIP
// disabled, binary hash mismatch, etc.), routing eligibility is cleared
// immediately because the provider actively failed a security check.
func (r *Registry) RecordChallengeFailure(providerID string, transientOnly bool) int {
	r.mu.RLock()
	p, ok := r.providers[providerID]
	r.mu.RUnlock()
	if !ok {
		return 0
	}

	p.mu.Lock()
	p.FailedChallenges++
	p.Reputation.RecordChallengeFail()
	count := p.FailedChallenges

	if !transientOnly {
		// Security failure — clear routing eligibility immediately.
		p.LastChallengeVerified = time.Time{}
		p.ChallengeVerifiedSIP = false
	} else if count >= MaxFailedChallenges {
		// Transient failures only clear after hitting the threshold.
		p.LastChallengeVerified = time.Time{}
		p.ChallengeVerifiedSIP = false
	}
	p.mu.Unlock()

	// Persist challenge state and reputation.
	r.persistProviderNow(p)
	r.persistReputation(p)

	return count
}

// RecordJobSuccess records a successful job completion for the provider's reputation.
func (r *Registry) RecordJobSuccess(providerID string, responseTime time.Duration) {
	r.mu.RLock()
	p, ok := r.providers[providerID]
	r.mu.RUnlock()
	if !ok {
		return
	}

	p.mu.Lock()
	p.Reputation.RecordJobSuccess(responseTime)
	p.mu.Unlock()

	// Persist reputation.
	r.persistReputation(p)
}

// RecordJobFailure records a failed job for the provider's reputation.
func (r *Registry) RecordJobFailure(providerID string) {
	r.mu.RLock()
	p, ok := r.providers[providerID]
	r.mu.RUnlock()
	if !ok {
		return
	}

	p.mu.Lock()
	p.Reputation.RecordJobFailure()
	p.mu.Unlock()

	// Persist reputation.
	r.persistReputation(p)
}
