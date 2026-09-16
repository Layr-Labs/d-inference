package verification

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

// VerifyMDA sends a DeviceInformation command requesting
// DevicePropertiesAttestation and verifies the Apple-signed certificate chain.
func (s *Verifier) VerifyMDA(ctx context.Context, providerID string, provider *registry.Provider, attestResult attestation.VerificationResult, udid string) {
	setOutcome := func(outcome string) {
		if metadata, ok := scheduledAttempt(ctx); ok {
			metadata.mdaOutcome = outcome
		}
	}
	// Fast path: reuse a still-valid, SE-key-bound Apple attestation recovered from
	// the durable store instead of requesting a fresh one. This skips the
	// rate-limited APNs round-trip entirely on reconnect/restart and is what keeps
	// mda_verified green across a provider restart.
	if s.AttachCachedMDA(providerID, provider, attestResult) {
		setOutcome("reused")
		return
	}

	if udid == "" {
		setOutcome("invalid")
		s.deps.Logger().Warn("no UDID for MDA verification")
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
	s.deps.Logger().Info("requesting Apple Device Attestation",
		"se_key_binding_requested", seKeyNonce != "",
	)

	// Install exclusive UDID and exact command ownership before command
	// visibility so an old late response cannot bind to this attempt.
	var observeMDACommand func(string, string)
	if _, scheduled := scheduledAttempt(ctx); scheduled &&
		s.deps.Scheduler() != nil {
		observeMDACommand = func(udid, commandUUID string) {
			s.deps.Scheduler().ObserveAttemptCommand(
				provider, store.VerificationTaskMDA,
				udid, commandUUID,
			)
		}
	}
	attestResp, err := s.deps.MDM().RequestDeviceAttestation(
		ctx, udid, seKeyNonce, 60*time.Second, observeMDACommand,
	)
	if err != nil {
		if strings.Contains(strings.ToLower(err.Error()), "timeout") {
			setOutcome("timeout")
		} else {
			setOutcome("transient")
		}
		s.deps.Logger().Warn("DevicePropertiesAttestation request failed", "error", err)
		return
	}

	// Verify the certificate chain against Apple's Enterprise Attestation Root CA
	mdaResult, err := attestation.VerifyMDADeviceAttestation(attestResp.CertChain)
	if err != nil {
		setOutcome("invalid")
		s.deps.Logger().Error("MDA certificate chain parse error", "error", err)
		return
	}

	if !mdaResult.Valid {
		setOutcome("invalid")
		s.deps.Logger().Warn("MDA certificate chain verification failed")
		return
	}

	// Cross-check: MDA serial must match the provider's self-reported serial
	if mdaResult.DeviceSerial != "" && mdaResult.DeviceSerial != attestResult.SerialNumber {
		setOutcome("binding_mismatch")
		s.deps.Logger().Error("MDA serial binding mismatch")
		s.deps.Registry().MarkUntrusted(providerID)
		return
	}

	// Apple Device Attestation verified — store the proof for coordinator-side
	// trust decisions and reuse. Public APIs expose only the redacted verdict.
	// Acquire provider lock since these fields are read by HTTP handlers
	// (handleProviderAttestation, handleChatCompletions) concurrently.
	seKeyBound := false
	if seKeyNonce != "" && len(mdaResult.FreshnessCode) > 0 {
		seKeyBound = bytes.Equal(mdaResult.FreshnessCode, expectedFreshness[:])
	}

	if seKeyNonce != "" && !seKeyBound {
		setOutcome("binding_mismatch")
		s.deps.Logger().Warn("MDA FreshnessCode did not bind the current Secure Enclave key")
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
	s.deps.Registry().PersistProvider(provider)

	s.deps.Logger().Info("MDA verified",
		"se_key_bound", seKeyBound,
		"freshness_code_present", len(mdaResult.FreshnessCode) > 0,
	)
}
