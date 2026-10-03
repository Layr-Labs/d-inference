package trust

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func (s *Owner) stageDurableMDAChain(provider *registry.Provider, serial string) {
	if s.store == nil || serial == "" {
		return
	}
	// Bound the store read: this runs on the attestation path, so a slow or
	// unavailable Postgres must not stall it — on timeout we skip staging and fall
	// back to a fresh attestation.
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	// Newest NON-EMPTY chain for this serial: a reconnect persists a new row that
	// may briefly carry an empty chain (async persists race the reattach), which
	// would shadow a still-valid chain via a plain by-serial lookup. This looks
	// past those empty rows.
	chain, err := s.store.GetMDAChainBySerial(ctx, serial)
	if err != nil || len(chain) == 0 {
		return
	}
	provider.StageMDAChainFromJSON(chain)
}

// attachCachedMDAProof tries to satisfy the Apple Device Attestation (MDA) leg
// from the durable cert chain restored on reconnect, WITHOUT a fresh
// DevicePropertiesAttestation round-trip. Apple rate-limits a fresh attestation to
// ≈1/device/7d and it rides the same throttled MicroMDM→APNs channel as
// SecurityInfo, so re-fetching on every reconnect is the reason restarted
// providers show "Apple Device Attestation incomplete". The cached chain is
// re-verified here against Apple's pinned Enterprise Attestation Root CA (an
// expired or tampered chain is rejected) and re-bound to THIS connection's SE key
// via the FreshnessCode OID (anti-relay). Returns true if a valid, bound proof was
// attached — which requires the provider to already hold hardware trust.
func (s *Owner) attachCachedMDAProof(providerID string, provider *registry.Provider, attestResult attestation.VerificationResult) bool {
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
	// (verifyAppleDeviceAttestation computes expectedFreshness = sha256([]byte(
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
	s.registry.PersistProvider(provider)
	s.logger.Info("MDA reused from durable SE-key-bound certificate chain")
	s.observation.Incr("mda.verification", []string{"outcome:reused"})
	return true
}

// verifyAppleDeviceAttestation sends a DeviceInformation command requesting
// DevicePropertiesAttestation and verifies the Apple-signed certificate chain.
func (s *Owner) verifyAppleDeviceAttestation(ctx context.Context, providerID string, provider *registry.Provider, attestResult attestation.VerificationResult, udid string) {
	setOutcome := func(outcome string) {
		if metadata, ok := ctx.Value(mdmSchedulerAttemptContextKey{}).(*mdmSchedulerAttemptMetadata); ok {
			metadata.mdaOutcome = outcome
		}
	}
	// Fast path: reuse a still-valid, SE-key-bound Apple attestation recovered from
	// the durable store instead of requesting a fresh one. This skips the
	// rate-limited APNs round-trip entirely on reconnect/restart and is what keeps
	// mda_verified green across a provider restart.
	if s.attachCachedMDAProof(providerID, provider, attestResult) {
		setOutcome("reused")
		return
	}

	if udid == "" {
		setOutcome("invalid")
		s.logger.Warn("no UDID for MDA verification")
		return
	}

	// Compute SE key hash for nonce-based key binding.
	// If the provider has an SE public key, include its hash as the
	// DeviceAttestationNonce (base64-encoded). Apple decodes the nonce and
	// embeds the raw bytes as FreshnessCode (OID 1.2.840.113635.100.8.11.1)
	// in the signed cert, cryptographically binding the SE key to genuine hardware.
	var seKeyNonce string
	var expectedFreshness [32]byte
	if attestResult.PublicKey != "" {
		seKeyHash := sha256.Sum256([]byte(attestResult.PublicKey))
		seKeyNonce = base64.StdEncoding.EncodeToString(seKeyHash[:])
		expectedFreshness = seKeyHash
	}
	s.logger.Info("requesting Apple Device Attestation",
		"se_key_binding_requested", seKeyNonce != "",
	)

	// Install exclusive UDID and exact command ownership before command
	// visibility so an old late response cannot bind to this attempt.
	var observeMDACommand func(string, string)
	if _, scheduled := ctx.Value(mdmSchedulerAttemptContextKey{}).(*mdmSchedulerAttemptMetadata); scheduled &&
		s.mdmScheduler != nil {
		observeMDACommand = func(udid, commandUUID string) {
			s.mdmScheduler.ObserveAttemptCommand(
				provider, store.VerificationTaskMDA,
				udid, commandUUID,
			)
		}
	}
	attestResp, err := s.mdmClient.RequestDeviceAttestation(
		ctx, udid, seKeyNonce, 60*time.Second, observeMDACommand,
	)
	if err != nil {
		if strings.Contains(strings.ToLower(err.Error()), "timeout") {
			setOutcome("timeout")
		} else {
			setOutcome("transient")
		}
		s.logger.Warn("DevicePropertiesAttestation request failed", "error", err)
		return
	}

	// Verify the certificate chain against Apple's Enterprise Attestation Root CA
	mdaResult, err := attestation.VerifyMDADeviceAttestation(attestResp.CertChain)
	if err != nil {
		setOutcome("invalid")
		s.logger.Error("MDA certificate chain parse error", "error", err)
		return
	}

	if !mdaResult.Valid {
		setOutcome("invalid")
		s.logger.Warn("MDA certificate chain verification failed")
		return
	}

	// Cross-check: MDA serial must match the provider's self-reported serial
	if mdaResult.DeviceSerial != "" && mdaResult.DeviceSerial != attestResult.SerialNumber {
		setOutcome("binding_mismatch")
		s.logger.Error("MDA serial binding mismatch")
		s.registry.MarkUntrusted(providerID)
		return
	}

	// Apple Device Attestation verified — store the proof for coordinator-side
	// trust decisions and reuse. Public APIs expose only the redacted verdict.
	// Acquire provider lock since these fields are read by HTTP handlers
	// (HandleProviderAttestation, handleChatCompletions) concurrently.
	seKeyBound := false
	if seKeyNonce != "" && len(mdaResult.FreshnessCode) > 0 {
		seKeyBound = bytes.Equal(mdaResult.FreshnessCode, expectedFreshness[:])
	}

	if seKeyNonce != "" && !seKeyBound {
		setOutcome("binding_mismatch")
		s.logger.Warn("MDA FreshnessCode did not bind the current Secure Enclave key")
		return
	}
	if !provider.SetMDAProofIfHardwareBound(attestResp.CertChain, mdaResult, seKeyBound) {
		setOutcome("invalid")
		return
	}
	setOutcome("verified")

	// Persist the freshly-earned chain NOW so it is durable for reuse. The
	// hardware-grant PersistProvider ran before this MDA leg, so without an explicit
	// write here the chain would only reach the store on the next throttled
	// heartbeat persist — and would be lost (and re-fetched, hitting Apple's
	// ~1/device/7d rate limit) if the provider disconnects in that window. With a
	// durable (Postgres) store this is what makes the proof recoverable across a
	// coordinator restart.
	s.registry.PersistProvider(provider)

	s.logger.Info("MDA verified",
		"se_key_bound", seKeyBound,
		"freshness_code_present", len(mdaResult.FreshnessCode) > 0,
	)
}

// providerAttestationCacheTTL bounds staleness of the public trust listing. It
// reflects live connection state (trust level, status, models), so it uses the
// same 2s window as GET /v1/models/capacity. The response is the same for every
// caller (unauthenticated, no query parameters).
