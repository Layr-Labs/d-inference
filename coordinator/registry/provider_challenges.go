package registry

import (
	"time"
)

// RecordChallengeSuccess records a successful challenge-response verification.
// A fully passing challenge re-verifies signature, SIP, secure boot, binary
// hash, model hash and runtime (see verifyChallengeResponse) before this is
// called, so it doubles as the recovery trigger for a *transiently* untrusted
// provider.
//
// Returns true iff this call recovered a transiently-untrusted provider back to
// online. The caller uses that to push a fresh "online" trust_status so the
// provider's locally persisted operator state reflects recovery.
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

	p.reconcileRuntimeCapabilities()

	// A newly verified (or newly recovered) provider may unlock queued requests
	// for any model it serves.
	r.drainQueuedRequestsForModelsWithReason(providerModelIDs(p), DrainTriggerChallenge)

	return recovered
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

// SetLastChallengeVerified updates the challenge timestamp (thread-safe).
func (p *Provider) SetLastChallengeVerified(t time.Time) {
	p.mu.Lock()
	p.LastChallengeVerified = t
	p.mu.Unlock()
}

// GetLastChallengeVerified returns the last challenge verification time (thread-safe).
func (p *Provider) GetLastChallengeVerified() time.Time {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.LastChallengeVerified
}

// GetChallengeVerifiedSIP returns whether SIP was verified in the last challenge (thread-safe).
func (p *Provider) GetChallengeVerifiedSIP() bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.ChallengeVerifiedSIP
}

func (p *Provider) SetChallengeVerifiedSIP(v bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.ChallengeVerifiedSIP = v
}

// ChallengeShouldStop reports whether the attestation challenge loop should
// stop for this provider. It stops only for a *hard* (non-recoverable) untrust;
// a transiently-untrusted provider keeps being challenged so a later passing
// challenge can restore it via RecordChallengeSuccess. Thread-safe.
func (p *Provider) ChallengeShouldStop() bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.Status == StatusUntrusted && !p.untrustedRecoverable
}

// RequestImmediateChallenge asks this connection's challenge loop to send an
// out-of-band attestation challenge now instead of waiting for the next
// periodic tick. Non-blocking; concurrent requests coalesce. No-op on bare
// test Providers without a kick channel.
func (p *Provider) RequestImmediateChallenge() {
	select {
	case p.challengeKick <- struct{}{}:
	default:
	}
}

// ImmediateChallengeChan is the challenge loop's receive side of
// RequestImmediateChallenge. Nil (never ready) on bare test Providers.
func (p *Provider) ImmediateChallengeChan() <-chan struct{} {
	return p.challengeKick
}
