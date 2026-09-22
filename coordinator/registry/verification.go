package registry

import "time"

// Verification is a public, identifier-free coordinator verdict. It is not raw
// Apple evidence and must never be used as a bearer authorization. Each path
// keeps its own clock; live consumers also bound the age of ObservedAt.
type Verification struct {
	ObservedAt int64            `json:"observed_at"`
	AppAttest  VerificationPath `json:"app_attest"`
	Legacy     VerificationPath `json:"legacy"`
}

type VerificationPath struct {
	State      string `json:"state"` // verified, pending, expired, revoked, unsupported, offline
	VerifiedAt int64  `json:"verified_at,omitempty"`
	ExpiresAt  int64  `json:"expires_at,omitempty"`
}

// ProviderAuthorizationSnapshot keeps public diagnostic fields and the
// owner-only compatibility authorization fields bound to one live observation.
type ProviderAuthorizationSnapshot struct {
	Verification           Verification
	AccountID              string
	Status                 ProviderStatus
	Authorized             bool
	AuthorizationExpiresAt int64
}

func (v Verification) Method() string {
	a, l := v.AppAttest.State == "verified", v.Legacy.State == "verified"
	switch {
	case a && l:
		return "dual"
	case a:
		return "app_attest"
	case l:
		return "legacy"
	default:
		return "none"
	}
}

func (r *Registry) ProviderVerification(p *Provider) Verification {
	return r.ProviderVerificationAndAuthorization(p).Verification
}

// ProviderVerificationAndAuthorization returns the diagnostic verdict and
// compatibility fields from one registry/provider-locked observation. Callers
// must still enforce the requesting account before exposing either field.
func (r *Registry) ProviderVerificationAndAuthorization(p *Provider) ProviderAuthorizationSnapshot {
	r.mu.RLock()
	defer r.mu.RUnlock()
	if p == nil || r.providers[p.ID] != p {
		return ProviderAuthorizationSnapshot{Verification: Verification{ObservedAt: time.Now().Unix(), AppAttest: VerificationPath{State: "offline"}, Legacy: VerificationPath{State: "offline"}}, Status: StatusOffline}
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	snapshot := ProviderAuthorizationSnapshot{
		Verification: r.providerVerificationLocked(p, time.Now()),
		AccountID:    p.AccountID,
		Status:       p.Status,
	}
	if snapshot.Verification.AppAttest.State == "verified" {
		snapshot.Authorized = true
		snapshot.AuthorizationExpiresAt = p.appAttestAuthorization.ValidUntil.Unix()
	}
	return snapshot
}

// ProviderVerifications avoids recursively taking r.mu inside ForEachProvider.
func (r *Registry) ProviderVerifications() map[string]Verification {
	r.mu.RLock()
	defer r.mu.RUnlock()
	out := make(map[string]Verification, len(r.providers))
	now := time.Now()
	for id, p := range r.providers {
		p.mu.Lock()
		out[id] = r.providerVerificationLocked(p, now)
		p.mu.Unlock()
	}
	return out
}

// ForEachProviderVerification reads membership, proof state and catalog models
// together. The callback runs under r.mu and p.mu: copy fields only; do not call
// registry/provider methods that acquire either lock or perform external I/O.
func (r *Registry) ForEachProviderVerification(fn func(*Provider, Verification, PublicProviderModelSnapshot)) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	for _, p := range r.providers {
		func() {
			p.mu.Lock()
			defer p.mu.Unlock()
			models := PublicProviderModelSnapshot{Models: []string{}}
			for _, model := range p.Models {
				if r.providerModelAllowedByCatalogLocked(p, model) {
					models.Models = append(models.Models, model.ID)
					if model.ID == p.CurrentModel {
						models.CurrentModel = model.ID
					}
				}
			}
			fn(p, r.providerVerificationLocked(p, time.Now()), models)
		}()
	}
}

func (r *Registry) providerVerificationLocked(p *Provider, now time.Time) Verification {
	v := Verification{ObservedAt: now.Unix(), AppAttest: VerificationPath{State: "pending"}, Legacy: VerificationPath{State: "pending"}}
	if p.Status == StatusOffline {
		v.AppAttest.State, v.Legacy.State = "offline", "offline"
		return v
	}
	_, credentialRevoked := r.appAttestRevokedCredentials[p.appAttestCredentialID]
	_, presenterRevoked := r.appAttestRevokedCredentials[p.appAttestPresenterID]
	if credentialRevoked || presenterRevoked || p.appAttestSecurityDenied {
		v.AppAttest.State, v.Legacy.State = "revoked", "revoked"
		return v
	}
	if p.appAttestProtocol != 3 {
		v.AppAttest.State = "unsupported"
	}
	a := p.appAttestAuthorization
	if r.providerAppAttestServingAuthorizedLocked(p, now) {
		v.AppAttest = VerificationPath{State: "verified", VerifiedAt: a.IssuedAt.Unix(), ExpiresAt: a.ValidUntil.Unix()}
	} else if !a.ValidUntil.IsZero() && !a.ValidUntil.After(now) {
		v.AppAttest.State = "expired"
	}
	// Legacy trust is evidence, not a current serving grant. Require the full
	// policy plus actual hardware trust even in permissive development configs.
	if p.TrustLevel == TrustHardware && r.providerLegacyServingAuthorizedLocked(p, now) {
		v.Legacy = VerificationPath{State: "verified", VerifiedAt: p.LastChallengeVerified.Unix(), ExpiresAt: p.LastChallengeVerified.Add(challengeFreshnessMaxAge).Unix()}
	} else if !p.LastChallengeVerified.IsZero() && now.Sub(p.LastChallengeVerified) > challengeFreshnessMaxAge {
		v.Legacy.State = "expired"
	}
	return v
}
