package registry

// SetCodeAttested updates general code-proof state at validated call sites.
// Persisted proof reuse never calls this with true: every new connection must
// first complete a live encrypted process-key possession challenge.
func (p *Provider) SetCodeAttested(v bool) {
	p.mu.Lock()
	p.CodeAttested = v
	if !v {
		p.FreshCodeAttested = false
		p.RuntimeCapabilities = nil
	}
	p.mu.Unlock()
	p.reconcileRuntimeCapabilities()
}

// SetFreshCodeAttested records a nonce round-trip completed by this live
// connection. It is never set by persisted/same-version reuse.
func (p *Provider) SetFreshCodeAttested() {
	p.mu.Lock()
	p.CodeAttested = true
	p.FreshCodeAttested = true
	p.mu.Unlock()
	p.reconcileRuntimeCapabilities()
}

// GrantProcessCodeAttested atomically binds a verified live response to the
// live token and registration X25519 process key. Rotation before grant fails;
// rotation after grant clears the state under the same provider lock.
func (p *Provider) GrantProcessCodeAttested(
	expectedToken, expectedNodeKey string,
) bool {
	p.mu.Lock()
	if expectedToken == "" || expectedNodeKey == "" ||
		p.APNsDeviceToken != expectedToken ||
		p.PublicKey != expectedNodeKey {
		p.mu.Unlock()
		return false
	}
	p.CodeAttested = true
	p.FreshCodeAttested = true
	p.mu.Unlock()
	p.reconcileRuntimeCapabilities()
	return true
}

func (p *Provider) RequiresFreshRuntimeCodeProof() bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	for _, capability := range p.ReportedRuntimeCapabilities {
		if capability == ProviderCapabilityAppleM5 ||
			capability == ProviderCapabilityMLXNAX {
			return true
		}
	}
	return false
}

func (p *Provider) GetFreshCodeAttested() bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.FreshCodeAttested
}

type CodeIdentityState struct {
	APNsDeviceToken        string
	Version                string
	SEPublicKey            string
	AttestationValid       bool
	RuntimeVerified        bool
	RuntimeManifestChecked bool
	ChallengeVerifiedSIP   bool
}

// GrantCodeAttestedIf runs `decide` against the live state and sets
// CodeAttested=true iff it returns true — atomically under the provider lock, so a
// concurrent token rotation can't interleave between the decision and the grant
// (closes the rotation TOCTOU). `decide` must not take this provider's lock; it
// may take others (e.g. the throttle) — lock order is always provider → throttle.
func (p *Provider) GrantCodeAttestedIf(decide func(CodeIdentityState) bool) bool {
	p.mu.Lock()
	st := CodeIdentityState{
		APNsDeviceToken:        p.APNsDeviceToken,
		Version:                p.Version,
		AttestationValid:       p.AttestationResult != nil && p.AttestationResult.Valid,
		RuntimeVerified:        p.RuntimeVerified,
		RuntimeManifestChecked: p.RuntimeManifestChecked,
		ChallengeVerifiedSIP:   p.ChallengeVerifiedSIP,
	}
	if p.AttestationResult != nil {
		st.SEPublicKey = p.AttestationResult.PublicKey
	}
	if !decide(st) {
		p.mu.Unlock()
		return false
	}
	p.CodeAttested = true
	p.mu.Unlock()
	p.reconcileRuntimeCapabilities()
	return true
}

// GetCodeAttested reports whether this connection passed code-identity
// attestation (thread-safe).
func (p *Provider) GetCodeAttested() bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.CodeAttested
}
