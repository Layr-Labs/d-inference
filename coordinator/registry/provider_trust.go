package registry

// SetHardUntrustHook registers an optional callback fired whenever a provider is
// HARD-untrusted (non-recoverable). It is invoked with the device's Secure Enclave
// public key, off the registry locks, so the callback may do store I/O. The api
// layer uses it to invalidate the device's trust-reuse record (DAR-326). Set once
// at startup before providers connect; nil clears it. Thread-safe.
func (r *Registry) SetHardUntrustHook(fn func(seKey string)) {
	r.mu.Lock()
	r.onHardUntrust = fn
	r.mu.Unlock()
}

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
	hook := r.onHardUntrust // capture under r.mu (race-safe)

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
	// transient (recoverable) untrust does NOT invalidate — it can self-recover via
	// a passing challenge.
	if !recoverable {
		// FIX A: bump the hard-untrust epoch BEFORE firing the delete hook. A
		// concurrent recordTrustReuse that captured the old epoch at grant time then
		// sees the change on its pre-upsert recheck and refuses to persist a stale
		// `hardware` row — closing the write-after-delete race (a write landing after
		// the synchronous delete that a restart would otherwise reseed).
		p.untrustEpoch.Add(1)
		if hook != nil && seKey != "" {
			hook(seKey)
		}
	}
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
	if level != TrustHardware {
		p.RuntimeCapabilities = nil
	}
	p.mu.Unlock()

	// Persist trust state.
	r.persistProviderNow(p)
	p.reconcileRuntimeCapabilities()
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

// trustMeetsMinimum returns true if the given trust level meets the minimum.
func (r *Registry) trustMeetsMinimum(level TrustLevel) bool {
	return trustRank(level) >= trustRank(r.MinTrustLevel)
}

// trustRank returns a numeric rank for trust levels (higher = more trusted).
// Returns -1 for unknown/invalid trust levels.
func trustRank(t TrustLevel) int {
	switch t {
	case TrustHardware:
		return 2
	case TrustSelfSigned:
		return 1
	case TrustNone:
		return 0
	default:
		return -1
	}
}

// GetTrustLevel returns the current trust level (thread-safe).
func (p *Provider) GetTrustLevel() TrustLevel {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.TrustLevel
}

// GetStatus returns the current provider status (thread-safe).
func (p *Provider) GetStatus() ProviderStatus {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.Status
}

// HardUntrustEpoch returns the current hard-untrust epoch (thread-safe). It is
// bumped on every hard untrust; the trust-reuse write-through captures it at grant
// time and re-checks it before persisting so a hard untrust that races a grant
// cannot leave a stale, reseedable `hardware` row (DAR-326 FIX A).
func (p *Provider) HardUntrustEpoch() uint64 {
	return p.untrustEpoch.Load()
}
