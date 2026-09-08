package api

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

// Compatibility path used only while the independent policy is in shadow.
func (s *Server) legacyAttachCachedMDAProof(providerID string, provider *registry.Provider, attestResult attestation.VerificationResult) bool {
	if s.processPostureEnforced() {
		return false
	}
	chain := provider.StagedMDAChain()
	if len(chain) == 0 {
		return false
	}
	mdaResult, err := attestation.VerifyMDADeviceAttestation(chain)
	if err != nil || mdaResult == nil || !mdaResult.Valid {
		return false
	}

	if attestResult.PublicKey == "" || len(mdaResult.FreshnessCode) == 0 {
		return false
	}
	want := sha256.Sum256([]byte(attestResult.PublicKey))
	if !bytes.Equal(mdaResult.FreshnessCode, want[:]) {
		return false
	}
	if mdaResult.DeviceSerial != "" && mdaResult.DeviceSerial != attestResult.SerialNumber {
		return false
	}

	if !provider.SetMDAProofIfHardwareBound(chain, mdaResult, true) {
		return false
	}
	s.registry.PersistProvider(provider)
	s.logger.Info("MDA reused from durable SE-key-bound certificate chain")
	s.ddIncr("mda.verification", []string{"outcome:reused"})
	return true
}

func (s *Server) legacyVerifyAppleDeviceAttestation(ctx context.Context, providerID string, provider *registry.Provider, attestResult attestation.VerificationResult, udid string) {
	if s.processPostureEnforced() {
		return
	}
	setOutcome := func(outcome string) {
		if metadata, ok := ctx.Value(mdmSchedulerAttemptContextKey{}).(*mdmSchedulerAttemptMetadata); ok {
			metadata.mdaOutcome = outcome
		}
	}
	if s.attachCachedMDAProof(providerID, provider, attestResult) {
		setOutcome("reused")
		return
	}

	if udid == "" {
		setOutcome("invalid")
		s.logger.Warn("no UDID for MDA verification")
		return
	}

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

	s.observeProcessPosture(provider, attestResult, udid, attestResp.CertChain, true, "fresh_mda")
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

	if mdaResult.DeviceSerial != "" && mdaResult.DeviceSerial != attestResult.SerialNumber {
		setOutcome("binding_mismatch")
		s.logger.Error("MDA serial binding mismatch")
		s.registry.MarkUntrusted(providerID)
		return
	}

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

	s.registry.PersistProvider(provider)

	s.logger.Info("MDA verified",
		"se_key_bound", seKeyBound,
		"freshness_code_present", len(mdaResult.FreshnessCode) > 0,
	)
}
