package registry

import (
	"errors"
	"time"
)

// AppAttestServingAuthorization is issued only after the API's full qualified
// policy succeeds. It belongs to one process/connection, is never persisted or
// restored as a bearer credential, and does not change legacy trust evidence.
type AppAttestServingAuthorization struct {
	AccountID, MachineID, CredentialID     string
	ConnectionID, ProofSessionID, Endpoint string
	PolicyGeneration                       uint64
	QualificationGeneration                uint64
	IssuedAt, ValidUntil                   time.Time
	// These assertions cover observed hardware matched to registration. They
	// are not Apple-certified immutable hardware specifications.
	MachineModel string
	MemoryGB     int
}

const maxAppAttestServingLease = 15 * time.Minute

var ErrProviderServingUnauthorized = errors.New("provider serving authorization is no longer valid")

// SetAppAttestServingPolicy changes serving authorization, not enrollment or
// MDM-removal rollout. Operators may stop new migrations while keeping serving
// enabled for machines already unenrolled. A generation change invalidates all
// old leases and requires the API to re-evaluate their evidence before granting.
func (r *Registry) SetAppAttestServingPolicy(enabled bool, generation uint64) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if !enabled || generation != r.appAttestPolicyGeneration {
		for _, p := range r.providers {
			p.mu.Lock()
			p.appAttestAuthorization = AppAttestServingAuthorization{}
			p.mu.Unlock()
		}
	}
	r.appAttestServingEnabled = enabled
	r.appAttestPolicyGeneration = generation
}

func (r *Registry) AppAttestServingPolicy() (bool, uint64) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return r.appAttestServingEnabled, r.appAttestPolicyGeneration
}

// GrantAppAttestServingAuthorization atomically rejects stale verifier results
// after revocation, replacement, key/account change or policy refresh. The
// caller must have completed runtime reconciliation and the strict App Attest
// verifier; this method is a second binding check, not a cryptographic verifier.
func (r *Registry) GrantAppAttestServingAuthorization(p *Provider, lease AppAttestServingAuthorization) bool {
	if p == nil {
		return false
	}
	r.mu.Lock()
	if r.providers[p.ID] != p {
		r.mu.Unlock()
		return false
	}
	p.mu.Lock()
	now := time.Now()
	if _, _, _, err := attestedRuntimeCapabilitiesLocked(p); err != nil {
		p.mu.Unlock()
		r.mu.Unlock()
		return false
	}
	previous := p.appAttestAuthorization
	previousStatus := p.Status
	recovering := p.Status == StatusUntrusted && p.untrustedRecoverable && !p.appAttestSecurityDenied
	if recovering {
		p.Status = StatusOnline
	}
	p.appAttestAuthorization = lease
	// Validate the same final gates used by dispatch before a recoverable
	// Untrusted connection is promoted or counted online. The failure branch
	// below restores both the previous lease and status atomically.
	valid := r.providerAppAttestServingAuthorizedLocked(p, now) &&
		!lease.IssuedAt.IsZero() && !lease.IssuedAt.After(now) &&
		lease.ValidUntil.Sub(lease.IssuedAt) <= maxAppAttestServingLease
	if !valid {
		p.appAttestAuthorization = previous
		p.Status = previousStatus
	} else {
		p.appAttestCredentialID = lease.CredentialID
		if recovering {
			p.untrustedRecoverable = false
			r.onlineCount.Add(1)
			for _, m := range p.Models {
				r.modelProviderInc(m.ID)
			}
		}
	}
	p.mu.Unlock()
	r.mu.Unlock()
	return valid
}

func (r *Registry) ClearAppAttestServingAuthorization(p *Provider) {
	if p == nil {
		return
	}
	p.mu.Lock()
	p.appAttestAuthorization = AppAttestServingAuthorization{}
	p.mu.Unlock()
}

// RefreshAppAttestServingState performs optional capability/queue fanout after
// the API releases its authorizer lock. The API schedules it on bounded workers
// because existing capability hooks can write to a provider's socket. Every
// promotion and queue decision re-reads current state; a delayed job cannot
// resurrect a cleared, expired, revoked or superseded lease.
func (r *Registry) RefreshAppAttestServingState(p *Provider) error {
	if p == nil || r.GetProvider(p.ID) != p {
		return ErrProviderServingUnauthorized
	}
	if err := r.ReconcileAttestedRuntimeCapabilities(p.ID); err != nil {
		return err
	}
	if _, valid := r.ProviderServingAuthorization(p); valid {
		r.drainQueuedRequestsForModelsWithReason(providerModelIDs(p), DrainTriggerChallenge)
	}
	return nil
}

func (p *Provider) GetAppAttestServingAuthorization() AppAttestServingAuthorization {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.appAttestAuthorization
}

// RevokeAppAttestCredential fences both authorization paths for every current
// connection using this credential before returning. Existing in-flight frames
// cannot be recalled. The deny set also prevents a late verifier result from
// granting the credential again; durable revocation is the API's responsibility.
func (r *Registry) RevokeAppAttestCredential(credentialID string) []string {
	if credentialID == "" {
		return nil
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.appAttestRevokedCredentials == nil {
		r.appAttestRevokedCredentials = make(map[string]struct{})
	}
	r.appAttestRevokedCredentials[credentialID] = struct{}{}
	var affected []string
	for id, p := range r.providers {
		p.mu.Lock()
		if p.appAttestCredentialID == credentialID || p.appAttestPresenterID == credentialID {
			r.denyAppAttestProviderLocked(p)
			affected = append(affected, id)
		}
		p.mu.Unlock()
	}
	return affected
}

// Caller holds r.mu and p.mu. The current pointer check is also performed at
// the final writer handoff, including when a same-ID connection was replaced.
func (r *Registry) providerHasAppAttestAuthorizationLocked(p *Provider, now time.Time) bool {
	a := p.appAttestAuthorization
	_, revoked := r.appAttestRevokedCredentials[a.CredentialID]
	return r.appAttestServingEnabled && !revoked && !p.appAttestSecurityDenied &&
		p.Status != StatusOffline && p.Status != StatusUntrusted &&
		a.PolicyGeneration != 0 && a.PolicyGeneration == r.appAttestPolicyGeneration &&
		a.QualificationGeneration == r.appAttestQualificationGeneration &&
		a.AccountID != "" && a.AccountID == p.AccountID &&
		a.MachineID != "" && a.MachineID == p.verifiedMachineID &&
		a.AccountID == p.verifiedMachineAccount && a.CredentialID != "" &&
		a.ConnectionID == p.ID && a.Endpoint != "" && a.Endpoint == p.PublicKey &&
		a.MachineModel != "" && a.MachineModel == p.Hardware.MachineModel &&
		a.MemoryGB > 0 && a.MemoryGB == p.Hardware.MemoryGB &&
		!a.IssuedAt.IsZero() && !a.IssuedAt.After(now) && a.ValidUntil.After(now)
}

// ProviderServingAuthorization reports a current App Attest lease suitable for
// a readiness response. It also requires common runtime/privacy gates; an
// expired or stale stored lease is never returned as removal readiness.
func (r *Registry) ProviderServingAuthorization(p *Provider) (AppAttestServingAuthorization, bool) {
	if p == nil {
		return AppAttestServingAuthorization{}, false
	}
	r.mu.RLock()
	defer r.mu.RUnlock()
	if r.providers[p.ID] != p {
		return AppAttestServingAuthorization{}, false
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	now := time.Now()
	if !r.providerAppAttestServingAuthorizedLocked(p, now) {
		return AppAttestServingAuthorization{}, false
	}
	return p.appAttestAuthorization, true
}

func (r *Registry) providerAppAttestServingAuthorizedLocked(p *Provider, now time.Time) bool {
	return r.providerHasAppAttestAuthorizationLocked(p, now) && p.RuntimeVerified &&
		!providerStateRestoreRequiredLocked(p) && r.providerSupportsPrivateTextAtLocked(p, now)
}

// ProviderLegacyServingAuthorized evaluates all current public legacy
// authorization gates, independently of any App Attest lease. Capacity and a
// loaded model are separate from authorization and are not required here.
func (r *Registry) ProviderLegacyServingAuthorized(p *Provider) bool {
	if p == nil {
		return false
	}
	r.mu.RLock()
	defer r.mu.RUnlock()
	if r.providers[p.ID] != p {
		return false
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	now := time.Now()
	return r.providerLegacyServingAuthorizedLocked(p, now)
}

func (r *Registry) providerLegacyServingAuthorizedLocked(p *Provider, now time.Time) bool {
	return p.Status != StatusOffline && p.Status != StatusUntrusted && !p.appAttestSecurityDenied &&
		!providerStateRestoreRequiredLocked(p) && r.trustMeetsMinimum(p.TrustLevel) &&
		p.RuntimeVerified && r.providerSupportsPrivateTextAuthorizationAtLocked(p, r.releasePolicyEnforcedAtLocked(now), false, now) &&
		!p.LastChallengeVerified.IsZero() && now.Sub(p.LastChallengeVerified) <= challengeFreshnessMaxAge
}

// ProviderServingDenialReason exposes only bounded operator diagnostics. It
// does not disclose credential/account/machine identifiers or synthesize legacy
// evidence; a recoverable missed legacy challenge is not a hard security denial.
func (r *Registry) ProviderServingDenialReason(p *Provider) string {
	if p == nil {
		return "connection_replaced"
	}
	r.mu.RLock()
	defer r.mu.RUnlock()
	if r.providers[p.ID] != p {
		return "connection_replaced"
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if _, revoked := r.appAttestRevokedCredentials[p.appAttestCredentialID]; revoked {
		return "credential_revoked"
	}
	if _, revoked := r.appAttestRevokedCredentials[p.appAttestPresenterID]; revoked {
		return "credential_revoked"
	}
	if p.appAttestSecurityDenied || (p.Status == StatusUntrusted && !p.untrustedRecoverable) {
		return "security_verification_failed"
	}
	return ""
}

func (r *Registry) providerTrustMeetsMinimumAtLocked(p *Provider, minimum TrustLevel, now time.Time) bool {
	return r.providerHasAppAttestAuthorizationLocked(p, now) || trustRank(p.TrustLevel) >= trustRank(minimum)
}

func (r *Registry) providerChallengeFreshAtLocked(p *Provider, now time.Time) bool {
	return r.providerHasAppAttestAuthorizationLocked(p, now) ||
		(!p.LastChallengeVerified.IsZero() && now.Sub(p.LastChallengeVerified) <= challengeFreshnessMaxAge)
}

// SetAppAttestQualificationGeneration fences only App Attest grants. It is
// independent of catalog generations and never changes legacy trust evidence.
func (r *Registry) SetAppAttestQualificationGeneration(generation uint64) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if generation == r.appAttestQualificationGeneration {
		return
	}
	r.appAttestQualificationGeneration = generation
	for _, p := range r.providers {
		p.mu.Lock()
		p.appAttestAuthorization = AppAttestServingAuthorization{}
		p.mu.Unlock()
	}
}
