package api

import (
	"bytes"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// verifyProviderViaMDM runs MDM verification in the background.
// If MDM confirms the device's security posture, the trust level is upgraded.
func (s *Server) verifyProviderViaMDM(providerID string, provider *registry.Provider, attestResult attestation.VerificationResult) {
	s.logger.Info("starting MDM verification",
		"provider_id", providerID,
		"serial_number", attestResult.SerialNumber,
	)

	mdmResult, err := s.mdmClient.VerifyProvider(
		attestResult.SerialNumber,
		attestResult.SIPEnabled,
		attestResult.SecureBootEnabled,
	)
	if err != nil {
		s.logger.Error("MDM verification error",
			"provider_id", providerID,
			"error", err,
		)
		return
	}

	if !mdmResult.DeviceEnrolled {
		s.logger.Warn("provider device not enrolled in MDM — staying at self_signed trust",
			"provider_id", providerID,
			"serial_number", attestResult.SerialNumber,
			"error", mdmResult.Error,
		)
		return
	}

	if mdmResult.Error != "" {
		// A timeout means APN latency or device sleep — not evidence of
		// compromise. Keep the provider at its current trust level (self_signed)
		// instead of marking it untrusted.
		if strings.Contains(mdmResult.Error, "timeout") {
			s.logger.Warn("MDM verification timed out — staying at current trust level",
				"provider_id", providerID,
				"error", mdmResult.Error,
			)
			return
		}
		s.logger.Warn("MDM verification failed — marking provider untrusted",
			"provider_id", providerID,
			"error", mdmResult.Error,
			"mdm_sip", mdmResult.MDMSIPEnabled,
			"mdm_secure_boot", mdmResult.MDMSecureBootFull,
			"sip_match", mdmResult.SIPMatch,
			"secure_boot_match", mdmResult.SecureBootMatch,
		)
		s.registry.MarkUntrusted(providerID)
		return
	}

	// MDM SecurityInfo verification passed — upgrade to hardware trust.
	provider.SetAttested(true, registry.TrustHardware)
	s.sendTrustStatus(provider, registry.TrustHardware, "online", "MDM verification passed")
	s.logger.Info("MDM verification passed — upgraded to hardware trust",
		"provider_id", providerID,
		"serial_number", attestResult.SerialNumber,
		"mdm_sip", mdmResult.MDMSIPEnabled,
		"mdm_secure_boot", mdmResult.MDMSecureBootFull,
		"mdm_auth_root_volume", mdmResult.MDMAuthRootVolume,
	)

	// Persist the trust upgrade.
	s.registry.PersistProvider(provider)

	// Request Apple Device Attestation — Apple's servers generate a
	// certificate chain that proves this device's identity. This cert
	// chain can be independently verified by users against Apple's
	// Enterprise Attestation Root CA.
	s.verifyAppleDeviceAttestation(providerID, provider, attestResult, mdmResult.UDID)
}

// verifyAppleDeviceAttestation sends a DeviceInformation command requesting
// DevicePropertiesAttestation and verifies the Apple-signed certificate chain.
func (s *Server) verifyAppleDeviceAttestation(providerID string, provider *registry.Provider, attestResult attestation.VerificationResult, udid string) {
	if udid == "" {
		s.logger.Warn("no UDID for MDA verification", "provider_id", providerID)
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
		s.logger.Info("requesting Apple Device Attestation (MDA) with SE key binding",
			"provider_id", providerID,
			"udid", udid,
			"se_key_hash", hex.EncodeToString(seKeyHash[:8])+"...",
		)
	} else {
		s.logger.Info("requesting Apple Device Attestation (MDA)",
			"provider_id", providerID,
			"udid", udid,
		)
	}

	// Always send the raw plist command so the nonce reaches Apple's servers.
	// The structured MicroMDM API doesn't support DeviceAttestationNonce.
	_, err := s.mdmClient.SendDeviceAttestationCommand(udid, seKeyNonce)
	if err != nil {
		s.logger.Warn("failed to send DeviceInformation attestation command",
			"provider_id", providerID,
			"error", err,
		)
		return
	}

	// Wait for Apple's response (device contacts Apple's servers — may take longer)
	attestResp, err := s.mdmClient.WaitForDeviceAttestation(udid, 60*time.Second)
	if err != nil {
		s.logger.Warn("DevicePropertiesAttestation response timeout",
			"provider_id", providerID,
			"error", err,
		)
		return
	}

	// Verify the certificate chain against Apple's Enterprise Attestation Root CA
	mdaResult, err := attestation.VerifyMDADeviceAttestation(attestResp.CertChain)
	if err != nil {
		s.logger.Error("MDA certificate chain parse error",
			"provider_id", providerID,
			"error", err,
		)
		return
	}

	if !mdaResult.Valid {
		s.logger.Warn("MDA certificate chain verification FAILED — Apple did not attest this device",
			"provider_id", providerID,
			"error", mdaResult.Error,
		)
		return
	}

	// Cross-check: MDA serial must match the provider's self-reported serial
	if mdaResult.DeviceSerial != "" && mdaResult.DeviceSerial != attestResult.SerialNumber {
		s.logger.Error("MDA serial mismatch — provider is impersonating another device",
			"provider_id", providerID,
			"mda_serial", mdaResult.DeviceSerial,
			"attestation_serial", attestResult.SerialNumber,
		)
		s.registry.MarkUntrusted(providerID)
		return
	}

	// Apple Device Attestation verified — store proof for user verification.
	// Acquire provider lock since these fields are read by HTTP handlers
	// (handleProviderAttestation, handleChatCompletions) concurrently.
	seKeyBound := false
	if seKeyNonce != "" && len(mdaResult.FreshnessCode) > 0 {
		seKeyBound = bytes.Equal(mdaResult.FreshnessCode, expectedFreshness[:])
	}

	provider.Mu().Lock()
	provider.MDAVerified = true
	provider.MDACertChain = attestResp.CertChain
	provider.MDAResult = mdaResult
	provider.SEKeyBound = seKeyBound
	provider.Mu().Unlock()

	// Log results.
	if seKeyNonce != "" && len(mdaResult.FreshnessCode) > 0 {
		if seKeyBound {
			s.logger.Info("MDA verified with SE key binding — Apple CA confirmed device + key",
				"provider_id", providerID,
				"mda_serial", mdaResult.DeviceSerial,
				"mda_udid", mdaResult.DeviceUDID,
				"se_key_bound", true,
			)
		} else {
			s.logger.Warn("MDA verified but FreshnessCode mismatch — SE key NOT bound",
				"provider_id", providerID,
				"mda_serial", mdaResult.DeviceSerial,
				"expected_freshness", hex.EncodeToString(expectedFreshness[:8])+"...",
				"got_freshness", hex.EncodeToString(mdaResult.FreshnessCode[:min(8, len(mdaResult.FreshnessCode))])+"...",
			)
		}
	} else {
		s.logger.Info("Apple Device Attestation (MDA) verified — Apple CA confirmed device identity",
			"provider_id", providerID,
			"mda_serial", mdaResult.DeviceSerial,
			"mda_udid", mdaResult.DeviceUDID,
			"mda_os_version", mdaResult.OSVersion,
			"mda_sepos_version", mdaResult.SepOSVersion,
			"se_key_bound", false,
			"freshness_code_len", len(mdaResult.FreshnessCode),
		)
	}
}
