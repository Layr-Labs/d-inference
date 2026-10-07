package registry

import "time"

// MarkUntrusted is the shared implementation. recoverable=true marks the untrust
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
func (l *ConnectionLifecycle) MarkUntrusted(providerID string, recoverable bool) {
	r := l.registry
	r.mu.Lock()
	p, ok := r.providers[providerID]
	if !ok {
		r.mu.Unlock()
		return
	}
	hook := r.onHardUntrust // capture under r.mu (race-safe)

	p.mu.Lock()
	// A missing legacy challenge is not negative security evidence. A live
	// independently valid App Attest lease can continue until its own deadline.
	if recoverable && r.providerHasAppAttestAuthorizationLocked(p, time.Now()) {
		p.mu.Unlock()
		r.mu.Unlock()
		return
	}
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
	// Never replay work across a transient distrust/recovery interval.
	p.warmWork.Reset()
	// Effective claims are connection security state, not durable inventory.
	// A passing fully-signed challenge may restore them only through reconcile.
	capabilitiesChanged := len(p.RuntimeCapabilities) > 0
	p.RuntimeCapabilities = nil
	failed := p.FailedChallenges // read under p.mu (the old code read this unlocked)
	// Capture the SE key for the hard-untrust hook while we hold p.mu.
	var seKey string
	if !recoverable && p.AttestationResult != nil {
		seKey = p.AttestationResult.PublicKey
	}
	if !recoverable {
		p.clearAppAttestServingAuthorizationLocked()
		if p.requireVerifiedMachineIdentity || p.appAttestCredentialID != "" {
			p.appAttestSecurityDenied = true
		}
		p.DeviceEvidence = DeviceEvidence{}
		p.ApplicationEvidence = ApplicationEvidence{}
		p.CodeAttested = false
		p.FreshCodeAttested = false
	}
	p.mu.Unlock()
	r.mu.Unlock()
	if !recoverable {
		p.SignalApplicationProofSettled()
	}
	if capabilitiesChanged {
		_ = r.ReconcileAttestedRuntimeCapabilities(providerID)
	}

	r.logger.Warn("provider marked as untrusted",
		"provider_id", providerID,
		"failed_challenges", failed,
		"recoverable", recoverable,
	)

	// A HARD untrust invalidates the device's trust-reuse record (in-memory +
	// persisted) so a later reconnect cannot fast-skip the live MDM re-verification
	// on a stale, pre-untrust record (DAR-326). Fired after releasing the locks; a
	// transient (recoverable) untrust does NOT invalidate - it can self-recover via
	// a passing challenge.
	if !recoverable {
		// FIX A: bump the hard-untrust epoch BEFORE firing the delete hook. A
		// concurrent recordTrustReuse that captured the old epoch at grant time then
		// sees the change on its pre-upsert recheck and refuses to persist a stale
		// `hardware` row - closing the write-after-delete race (a write landing after
		// the synchronous delete that a restart would otherwise reseed).
		p.untrustEpoch.Add(1)
		if hook != nil && seKey != "" {
			hook(seKey)
		}
	}
}

// RecoverTransientlyUntrusted promotes a transiently-untrusted provider back
// to online, mirroring MarkUntrusted's bookkeeping in reverse. Returns true iff
// a transition occurred. It acquires r.mu (write) then p.mu - the same order as
// MarkUntrusted/Register/Disconnect - so online/model counts stay consistent and
// the path is deadlock-free.
func (l *ConnectionLifecycle) RecoverTransientlyUntrusted(providerID string, p *Provider) bool {
	r := l.registry
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
