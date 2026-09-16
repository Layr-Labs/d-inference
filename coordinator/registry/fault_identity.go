package registry

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry/faultstate"
)

// stableProviderIdentityLocked derives a provider's stable identity (precedence:
// hardware serial → SE public key → account id), or "" when none is available
// (un-attestable → never ejected, fail-open).
//
// Serial and SE key are trusted ONLY from a VALID attestation result: both come
// from the attestation blob, which is attacker-supplied until its signature
// verifies, so an invalid result can carry another machine's serial — deriving
// an identity from it would bind a hostile session's fault state under
// "serial:<victim>" and deroute the legitimate machine when it reconnects.
// Valid-gating (not MDA-gating) is deliberate: VerificationResult carries no
// MDA/trust field — that state lives on Provider and is granted later by the
// bounded MDM/MDA scheduler. A Valid-but-uncrosschecked serial cannot accumulate
// served-fault state in production because routing requires hardware trust, and
// every grant still cross-checks the attested serial/device identity.
// The account fallback is safe on any result: AccountID is stamped from the
// authenticated provider token at registration, never from the attestation blob.
//
// Reads p.AttestationResult / p.AccountID DIRECTLY — it must NOT take p.mu. The
// routing gate (providerPassesRoutingGatesLockedEx) calls this with p.mu ALREADY
// HELD (snapshotProviderLocked* holds it; the gate reads p.Status/p.TrustLevel the
// same direct way), so re-locking via p.GetAttestationResult() self-deadlocks the
// gate. The only lock-free caller, GetProviderStableIdentity, takes p.mu itself
// before calling — so every path reads these fields under p.mu without re-entrancy.
func stableProviderIdentityLocked(p *Provider) string {
	if p == nil {
		return ""
	}
	if ar := p.AttestationResult; ar != nil && ar.Valid {
		if ar.SerialNumber != "" {
			return "serial:" + ar.SerialNumber
		}
		if ar.PublicKey != "" {
			return "sekey:" + ar.PublicKey
		}
	}
	if p.AccountID != "" {
		return "acct:" + p.AccountID
	}
	return ""
}

// GetProviderStableIdentity resolves a live session providerID to its stable
// identity, or "" if the provider is gone or un-attestable. For the consumer
// note* hooks to feed RecordProviderServeOutcome without holding registry locks:
// the session index under gatesMu stands in for r.providers, so this never
// queues behind a registry writer.
func (r *Registry) GetProviderStableIdentity(providerID string) string {
	if providerID == "" {
		return ""
	}
	p, cachedID, cachedAt, hasCached := r.faults.IdentitySource(providerID)
	if p != nil {
		// This path does NOT hold p.mu (unlike the routing gate), so take it for the
		// read — guarding against a concurrent SetAttestationResult (live re-attestation
		// writes p.AttestationResult under p.mu). Not nested with gatesMu, so no deadlock.
		p.mu.Lock()
		defer p.mu.Unlock()
		return stableProviderIdentityLocked(p)
	}
	// Provider already removed from the session index — typically because
	// Disconnect ran before the pending-request ErrorCh flush, which carries the
	// 502 "provider disconnected" faults that characterize a reconnecting zombie.
	// Fall back to the identity captured at disconnect so those faults are still
	// recorded against the stable-identity breaker (otherwise the dominant zombie
	// signal is never counted).
	if hasCached && time.Since(cachedAt) < faultstate.DisconnectedIdentityTTL {
		return cachedID
	}
	return ""
}
