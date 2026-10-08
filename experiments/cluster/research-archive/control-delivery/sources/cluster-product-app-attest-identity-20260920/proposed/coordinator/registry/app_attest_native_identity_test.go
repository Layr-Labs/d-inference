package registry

import (
	"encoding/base64"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func appAttestNativeIdentityFixture(t *testing.T) (*Registry, *Provider, AppAttestServingAuthorization) {
	t.Helper()
	r, p, lease := appAttestTestProvider(t)
	t.Cleanup(func() { r.Disconnect(p.ID) })
	r.mu.Lock()
	p.mu.Lock()
	r.releasePolicyGeneration = lease.PolicyGeneration
	p.PublicKey = base64.StdEncoding.EncodeToString([]byte(strings.Repeat("e", 32)))
	p.Attested, p.MDAVerified, p.SEKeyBound, p.CodeAttested, p.FreshCodeAttested = false, false, false, false, false
	p.TrustLevel = TrustNone
	p.RuntimeVerified, p.RuntimeManifestChecked, p.MetallibVerified = true, true, true
	p.TemplateHashes = map[string]string{"mlx_metallib": strings.Repeat("b", 64)}
	p.AttestationResult = &attestation.VerificationResult{
		Valid: true, PublicKey: "BGsX0fLhLEJH+Lzm5WOkQPJ3A32BLeszoPShOUXYmMKWT+NC4v4af5uO5+tKfA+eFivOM1drMV7Oy7ZAaDe/UfU=",
		EncryptionPublicKey: p.PublicKey, BinaryHash: strings.Repeat("a", 64), MetallibHash: strings.Repeat("b", 64),
		ChipFamily: p.Hardware.ChipFamily, RuntimeCapabilities: p.ReportedRuntimeCapabilities,
		SerialNumber: "unverified-serial-must-not-escape",
	}
	lease.Endpoint = p.PublicKey
	lease.VerifiedControlPublicKey, lease.VerifiedBinaryHash = p.AttestationResult.PublicKey, p.AttestationResult.BinaryHash
	lease.VerifiedMetallibHash = p.AttestationResult.MetallibHash
	p.mu.Unlock()
	r.mu.Unlock()
	if !r.GrantAppAttestServingAuthorization(p, lease) {
		t.Fatal("synthetic qualified lease fixture")
	}
	return r, p, lease
}

func readAppAttestNativeIdentity(r *Registry, p *Provider, now time.Time) (protocol.NativeMemberIdentity, bool) {
	r.mu.RLock()
	defer r.mu.RUnlock()
	p.mu.Lock()
	defer p.mu.Unlock()
	return r.appAttestNativeIdentityLocked(p, now)
}

func TestAppAttestNativeIdentityUsesVerifiedContinuityWithoutLegacyEvidence(t *testing.T) {
	r, p, lease := appAttestNativeIdentityFixture(t)
	got, ok := readAppAttestNativeIdentity(r, p, time.Now())
	if !ok || got.Kind != protocol.NativeIdentityAppAttest || got.DeviceSerial != "" || got.AccountID != lease.AccountID || got.MachineID != lease.MachineID || got.CredentialID != lease.CredentialID || got.ProofSessionID != lease.ProofSessionID || got.ControlPublicKey != lease.VerifiedControlPublicKey || got.ProcessPublicKey != lease.Endpoint {
		t.Fatal("identity projection")
	}
	p.mu.Lock()
	legacy := p.MDAVerified || p.SEKeyBound || p.CodeAttested || p.FreshCodeAttested || p.TrustLevel != TrustNone
	p.mu.Unlock()
	if legacy {
		t.Fatal("legacy flags synthesized")
	}
	// A same-proof refresh changes its local deadline, never its stable identity.
	lease.ValidUntil = lease.ValidUntil.Add(-time.Second)
	if !r.GrantAppAttestServingAuthorization(p, lease) {
		t.Fatal("renewal")
	}
	renewed, ok := readAppAttestNativeIdentity(r, p, time.Now())
	if !ok || got != renewed {
		t.Fatal("renewal changed identity")
	}
	if _, ok := readAppAttestNativeIdentity(r, p, lease.ValidUntil); ok {
		t.Fatal("exclusive expiry")
	}
}

func TestAppAttestNativeIdentityRefusesStaleOrSubstitutedAuthority(t *testing.T) {
	changes := map[string]func(*Registry, *Provider){
		"replaced": func(r *Registry, p *Provider) { r.providers[p.ID] = &Provider{ID: p.ID} },
		"account":  func(_ *Registry, p *Provider) { p.AccountID = "replacement" },
		"machine":  func(_ *Registry, p *Provider) { p.verifiedMachineID = "replacement" },
		"revoked": func(r *Registry, p *Provider) {
			r.appAttestRevokedCredentials = map[string]struct{}{p.appAttestAuthorization.CredentialID: {}}
		},
		"denied":        func(_ *Registry, p *Provider) { p.appAttestSecurityDenied = true },
		"disabled":      func(r *Registry, _ *Provider) { r.appAttestServingEnabled = false },
		"policy":        func(r *Registry, _ *Provider) { r.appAttestPolicyGeneration++ },
		"release":       func(r *Registry, _ *Provider) { r.releasePolicyGeneration++ },
		"endpoint":      func(_ *Registry, p *Provider) { p.PublicKey = "replacement" },
		"signer":        func(_ *Registry, p *Provider) { p.AttestationResult.PublicKey = "replacement" },
		"registration":  func(_ *Registry, p *Provider) { p.AttestationResult.Valid = false },
		"binary":        func(_ *Registry, p *Provider) { p.AttestationResult.BinaryHash = strings.Repeat("c", 64) },
		"metal":         func(_ *Registry, p *Provider) { p.TemplateHashes["mlx_metallib"] = strings.Repeat("c", 64) },
		"runtime":       func(_ *Registry, p *Provider) { p.RuntimeManifestChecked = false },
		"metalApproval": func(_ *Registry, p *Provider) { p.MetallibVerified = false },
		"proof":         func(_ *Registry, p *Provider) { p.appAttestAuthorization.ProofSessionID = "" },
		"expired":       func(_ *Registry, p *Provider) { p.appAttestAuthorization.ValidUntil = time.Now().Add(-time.Second) },
	}
	for name, change := range changes {
		t.Run(name, func(t *testing.T) {
			r, p, _ := appAttestNativeIdentityFixture(t)
			r.mu.Lock()
			p.mu.Lock()
			change(r, p)
			p.mu.Unlock()
			r.mu.Unlock()
			if _, ok := readAppAttestNativeIdentity(r, p, time.Now()); ok {
				t.Fatal("stale identity accepted")
			}
		})
	}
}

func TestAppAttestNativeIdentityDoesNotInferSignerFromOldLease(t *testing.T) {
	r, p, lease := appAttestNativeIdentityFixture(t)
	lease.VerifiedControlPublicKey, lease.VerifiedBinaryHash, lease.VerifiedMetallibHash = "", "", ""
	if !r.GrantAppAttestServingAuthorization(p, lease) {
		t.Fatal("old ordinary lease behavior changed")
	}
	if _, ok := readAppAttestNativeIdentity(r, p, time.Now()); ok {
		t.Fatal("inferred control signer from endpoint/registration alone")
	}
}

func TestAppAttestGrantRechecksCarriedControlBinding(t *testing.T) {
	changes := []func(*AppAttestServingAuthorization){
		func(a *AppAttestServingAuthorization) { a.VerifiedControlPublicKey = "" },
		func(a *AppAttestServingAuthorization) { a.VerifiedBinaryHash = "" },
		func(a *AppAttestServingAuthorization) { a.VerifiedControlPublicKey = a.Endpoint },
		func(a *AppAttestServingAuthorization) { a.VerifiedBinaryHash = strings.Repeat("c", 64) },
	}
	for _, change := range changes {
		r, p, lease := appAttestNativeIdentityFixture(t)
		before := p.GetAppAttestServingAuthorization()
		change(&lease)
		if r.GrantAppAttestServingAuthorization(p, lease) {
			t.Fatal("substitution granted")
		}
		if p.GetAppAttestServingAuthorization() != before {
			t.Fatal("failed grant replaced current lease")
		}
	}
}
