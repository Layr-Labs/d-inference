package verification

import (
	"bytes"
	"crypto/sha256"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// AttachCachedMDA tries to satisfy the Apple Device Attestation (MDA) leg
// from the durable cert chain restored on reconnect, WITHOUT a fresh
// DevicePropertiesAttestation round-trip. Apple rate-limits a fresh attestation to
// ≈1/device/7d and it rides the same throttled MicroMDM→APNs channel as
// SecurityInfo, so re-fetching on every reconnect is the reason restarted
// providers show "Apple Device Attestation incomplete". The cached chain is
// re-verified here against Apple's pinned Enterprise Attestation Root CA (an
// expired or tampered chain is rejected) and re-bound to THIS connection's SE key
// via the FreshnessCode OID (anti-relay). Returns true if a valid, bound proof was
// attached — which requires the provider to already hold hardware trust.
func (s *Verifier) AttachCachedMDA(providerID string, provider *registry.Provider, attestResult attestation.VerificationResult) bool {
	chain := provider.StagedMDAChain()
	if len(chain) == 0 {
		return false
	}
	mdaResult, err := attestation.VerifyMDADeviceAttestation(chain)
	if err != nil || mdaResult == nil || !mdaResult.Valid {
		// Chain no longer verifies (expired / not Apple-signed) — fall through to a
		// fresh request.
		return false
	}

	// Cached reuse REQUIRES the strong SE-key binding: the FreshnessCode OID in the
	// Apple-signed chain must equal SHA-256 of THIS connection's SE public key. A
	// serial-only match is deliberately NOT sufficient to reuse a stored chain — if
	// the SE key rotated (re-image / keychain reset) the old chain no longer binds
	// this key, so we fall through to a fresh attestation rather than letting a new
	// key inherit the prior device's Apple proof. (A live challenge has already
	// proven possession of this SE key, so the binding is meaningful.)
	if attestResult.PublicKey == "" || len(mdaResult.FreshnessCode) == 0 {
		return false
	}
	// INVARIANT: this must use the exact same input as the fresh path's nonce
	// (VerifyMDA computes expectedFreshness = sha256([]byte(
	// attestResult.PublicKey)) and sends its base64 as the DeviceAttestationNonce).
	// Apple echoes the decoded nonce as the FreshnessCode, so a chain earned fresh
	// has FreshnessCode == this digest. Keep the two formulas identical.
	want := sha256.Sum256([]byte(attestResult.PublicKey))
	if !bytes.Equal(mdaResult.FreshnessCode, want[:]) {
		return false
	}
	// Defense in depth: when Apple included a serial, it must match this machine's
	// attested serial (privacy-enrolled chains omit the serial — the SE-key binding
	// above carries the proof in that case).
	if mdaResult.DeviceSerial != "" && mdaResult.DeviceSerial != attestResult.SerialNumber {
		return false
	}

	if !provider.SetMDAProofIfHardwareBound(chain, mdaResult, true) {
		// Not hardware-trusted (yet) — nothing to attach the proof to.
		return false
	}
	// Persist immediately under THIS connection's record. The grant-path
	// PersistProvider ran before this attach, so without this write the new
	// session's row would carry an empty mda_cert_chain until the next throttled
	// heartbeat — and a disconnect in that window would lose the chain (serial now
	// indexes this session's row), forcing a fresh, rate-limited refetch on the
	// next reconnect. Mirrors the fresh-MDA path's immediate persist.
	s.deps.Registry().PersistProvider(provider)
	s.deps.Logger().Info("MDA reused from durable SE-key-bound certificate chain")
	s.deps.Incr("mda.verification", []string{"outcome:reused"})
	return true
}
