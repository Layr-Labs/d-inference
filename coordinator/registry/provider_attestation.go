package registry

import (
	"github.com/eigeninference/d-inference/coordinator/attestation"
)

// SetAttested updates attestation state (thread-safe).
// Note: persistence is handled by the Registry methods that call this,
// via persistProvider() after attestation verification completes.
func (p *Provider) SetAttested(attested bool, trust TrustLevel) {
	p.mu.Lock()
	p.Attested = attested
	p.TrustLevel = trust
	if !attested || trust != TrustHardware {
		p.RuntimeCapabilities = nil
	}
	p.mu.Unlock()
	p.reconcileRuntimeCapabilities()
}

// SetAttestationResult stores an immutable snapshot of the parsed attestation
// result. It copies both the struct and its capability slice: the registration
// path continues mutating its local result while persistence may concurrently
// marshal the Provider snapshot.
func (p *Provider) SetAttestationResult(result *attestation.VerificationResult) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if result == nil {
		p.AttestationResult = nil
	} else {
		snapshot := *result
		snapshot.RuntimeCapabilities = append(
			[]string(nil), result.RuntimeCapabilities...)
		p.AttestationResult = &snapshot
	}
	// Re-derive the stable identity and bind it while p.mu is STILL held
	// (lock order r.mu → p.mu → gatesMu → gate.mu; bindStableFaultKey takes the
	// last two). Changing the gate bound to p.faultSession must not land inside a
	// section that reads p.faultSession and acts on it under p.mu: the reservation
	// commit's admit re-check through its pending debit, the scan's gate chain,
	// the alias resolver's routability read. Binding at attestation time is what
	// re-attaches a reconnecting machine's fault state (breakers/cooldowns keyed
	// by serial/SE-key) to its fresh session id BEFORE it becomes routable —
	// public routing requires attestation.
	if r := p.registry; r != nil {
		r.bindStableFaultKey(p, stableProviderIdentityLocked(p))
	}
}

// RebindStableFaultKey re-derives this session's stable identity and re-binds
// its fault key. Account linkage happens AFTER the registration-time
// attestation bind (api/provider.go resolves the auth token only once
// Register + verification.Verifier.VerifyRegistration have returned), so a provider whose
// identity resolves to the ACCOUNT fallback — attestation absent (Open Mode)
// or invalid — would otherwise never bind: all its fault state would key by
// session UUID and be wiped on reconnect. Same lock discipline as
// SetAttestationResult: derive AND bind under p.mu.
func (p *Provider) RebindStableFaultKey() {
	p.mu.Lock()
	defer p.mu.Unlock()
	if r := p.registry; r != nil {
		r.bindStableFaultKey(p, stableProviderIdentityLocked(p))
	}
}

// GetAttestationResult returns the current attestation result (thread-safe).
func (p *Provider) GetAttestationResult() *attestation.VerificationResult {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.AttestationResult
}

// TruncHash returns the first 16 chars of a hash string for logging.
func TruncHash(h string) string {
	if len(h) > 16 {
		return h[:16] + "..."
	}
	return h
}
