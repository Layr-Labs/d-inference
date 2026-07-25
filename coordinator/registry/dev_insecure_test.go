package registry

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// devInsecureProvider registers a provider that carries the end-to-end crypto
// fields (X25519 public key, mlx-swift backend, encrypted response chunks) but
// presents every attestation/hardening signal in the un-hardened state a real
// dev provider (DARKBLOOM_DEV_INSECURE) would: no verified runtime manifest, no
// coordinator-verified SIP, no privacy hardening, no fresh attestation
// challenge, and TrustNone. This is exactly the provider a dev-insecure
// coordinator must route and a normal coordinator must refuse.
func devInsecureProvider(reg *Registry, id string) *Provider {
	msg := testRegisterMessage()
	msg.Backend = BackendMLXSwift
	// A non-hardened dev build reports its hardening flags as false.
	msg.PrivacyCapabilities = &protocol.PrivacyCapabilities{
		TextBackendInprocess: true,
		TextProxyDisabled:    true,
		AntiDebugEnabled:     false,
		CoreDumpsDisabled:    false,
		EnvScrubbed:          false,
	}
	p := reg.Register(id, nil, msg)
	// Wind the attestation/hardening state back to what an un-attested dev
	// provider actually presents (Register defaults some of these to "verified").
	p.TrustLevel = TrustNone
	p.RuntimeVerified = false
	p.RuntimeManifestChecked = false
	p.ChallengeVerifiedSIP = false
	p.LastChallengeVerified = time.Time{}
	return p
}

// TestDevInsecureRoutesUnattestedProvider proves the dev-insecure relaxation:
// an E2E-capable but completely un-attested provider is routable.
func TestDevInsecureRoutesUnattestedProvider(t *testing.T) {
	reg := New(testLogger())
	reg.DevInsecure = true
	reg.MinTrustLevel = TrustNone // main.go forces this when DEV_INSECURE is set
	p := devInsecureProvider(reg, "p-dev-insecure")

	reg.mu.RLock()
	defer reg.mu.RUnlock()
	if !reg.providerSupportsPrivateTextLocked(p) {
		t.Fatal("dev-insecure: E2E-capable but un-attested provider must support private text")
	}
	if !reg.providerLivenessGateLocked(p, reg.MinTrustLevel, false, time.Now()) {
		t.Fatal("dev-insecure: un-attested provider must pass the liveness gate")
	}
}

// TestDevInsecureDisabledRejectsUnattestedProvider is the regression guard: the
// SAME provider must be refused when DevInsecure is off, so the relaxation is
// provably the only reason it routes above.
func TestDevInsecureDisabledRejectsUnattestedProvider(t *testing.T) {
	reg := New(testLogger()) // DevInsecure defaults false
	p := devInsecureProvider(reg, "p-strict")

	reg.mu.RLock()
	defer reg.mu.RUnlock()
	if reg.providerSupportsPrivateTextLocked(p) {
		t.Fatal("strict mode: un-attested provider must NOT support private text")
	}
	if reg.providerLivenessGateLocked(p, TrustNone, false, time.Now()) {
		t.Fatal("strict mode: un-attested provider must NOT pass the liveness gate")
	}
}

// TestDevInsecureStillRequiresE2E proves the crypto floor is never relaxed:
// even with all attestation/hardening disabled, a provider missing any E2E
// requirement is not routable for private text.
func TestDevInsecureStillRequiresE2E(t *testing.T) {
	cases := []struct {
		name   string
		mutate func(p *Provider)
	}{
		{"no_public_key", func(p *Provider) { p.PublicKey = "" }},
		{"chunks_not_encrypted", func(p *Provider) { p.EncryptedResponseChunks = false }},
		{"non_swift_backend", func(p *Provider) { p.Backend = "inprocess-mlx" }},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			reg := New(testLogger())
			reg.DevInsecure = true
			reg.MinTrustLevel = TrustNone
			p := devInsecureProvider(reg, "p-"+tc.name)
			tc.mutate(p)

			reg.mu.RLock()
			defer reg.mu.RUnlock()
			if reg.providerSupportsPrivateTextLocked(p) {
				t.Fatalf("dev-insecure must still enforce E2E: %s should not be routable", tc.name)
			}
		})
	}
}
