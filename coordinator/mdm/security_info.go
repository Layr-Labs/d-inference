package mdm

import (
	"context"
	"fmt"
	"time"
)

// SecurityInfoResponse parsed from the MDM SecurityInfo command response.
type SecurityInfoResponse struct {
	UDID                             string
	SystemIntegrityProtectionEnabled bool
	SecureBootLevel                  string // "full", "reduced", "permissive"
	AuthenticatedRootVolumeEnabled   bool
	FirewallEnabled                  bool
	FileVaultEnabled                 bool
	IsRecoveryLockEnabled            bool
	RemoteDesktopEnabled             bool
}

// VerificationResult from cross-checking MDM with attestation.
type VerificationResult struct {
	DeviceEnrolled    bool
	UDID              string
	SerialNumber      string
	MDMSIPEnabled     bool
	MDMSecureBootFull bool
	MDMAuthRootVolume bool
	MDMRecoveryLocked bool // Recovery Lock prevents Recovery OS access (blocks rdma_ctl enable)
	SIPMatch          bool // MDM SIP matches attestation SIP
	SecureBootMatch   bool // MDM SecureBoot matches attestation

	// SecurityMismatch is true ONLY for a genuine posture failure proven by a
	// received SecurityInfo response: SIP disabled, Secure Boot not full, or the
	// MDM-reported posture disagreeing with the provider's attestation. It is the
	// single signal callers use to decide a hard (terminal) untrust. It is FALSE
	// for every "could not complete the check" condition (device not found / not
	// enrolled, command send failure, SecurityInfo timeout, context cancellation),
	// so a transient MicroMDM/APNs problem never hard-untrusts an enrolled box.
	SecurityMismatch bool

	Error string
}

// VerifyProviderWithUDIDObserver publishes transport identity in two phases:
// enrolled UDID after the exclusive waiter exists, then exact command UUID after
// MicroMDM returns and binds it.
func (c *Client) VerifyProviderWithUDIDObserver(
	ctx context.Context,
	serialNumber string,
	attestationSIP, attestationSecureBoot bool,
	observeUDID func(string),
	observeCommand func(udid, commandUUID string),
) (*VerificationResult, error) {
	result := &VerificationResult{SerialNumber: serialNumber}

	// Step 1: Look up device.
	device, err := c.LookupDevice(ctx, serialNumber)
	if err != nil {
		result.Error = fmt.Sprintf("device lookup failed: %v", err)
		return result, nil
	}

	if device == nil {
		result.Error = "device not found in MDM — provider must install enrollment profile"
		return result, nil
	}

	result.DeviceEnrolled = device.EnrollmentStatus
	result.UDID = device.UDID

	if !device.EnrollmentStatus {
		result.Error = "device found but not enrolled in MDM"
		return result, nil
	}

	// Step 2: Register the response waiter BEFORE sending/pushing. The send path
	// pushes the device synchronously, so an awake device can answer before we'd
	// otherwise install the waiter; registering first guarantees the webhook finds
	// it and the in-flight verifier sees the response (instead of timing out and
	// relying on the late callback).
	ch, bind, release, err := c.registerSecurityInfoWaiter(device.UDID)
	if err != nil {
		result.Error = err.Error()
		return result, nil
	}
	defer release()
	if observeUDID != nil && result.UDID != "" {
		observeUDID(result.UDID)
	}
	bindObservedCommand := func(commandUUID string) bool {
		if !bind(commandUUID) {
			return false
		}
		if observeCommand != nil {
			observeCommand(device.UDID, commandUUID)
		}
		return true
	}

	// Step 3: send once, binding this waiter to the exact issued UUID before the
	// issued-command gate can dispatch a fast webhook.
	if _, err = c.sendSecurityInfoCommand(
		ctx, device.UDID, bindObservedCommand,
	); err != nil {
		result.Error = fmt.Sprintf("failed to send SecurityInfo command: %v", err)
		return result, nil
	}

	// Step 4: Wait for the response (via webhook). 90 seconds allows for APN
	// delivery delays during Power Nap cycles (every ~15 minutes on AC). Returns
	// early if ctx is cancelled (provider disconnected).
	secInfo, err := awaitSecurityInfo(ctx, ch, 90*time.Second)
	if err != nil {
		result.Error = fmt.Sprintf("SecurityInfo response: %v", err)
		return result, nil
	}

	// Step 4: Populate result
	result.MDMSIPEnabled = secInfo.SystemIntegrityProtectionEnabled
	result.MDMSecureBootFull = secInfo.SecureBootLevel == "full"
	result.MDMAuthRootVolume = secInfo.AuthenticatedRootVolumeEnabled
	result.MDMRecoveryLocked = secInfo.IsRecoveryLockEnabled

	// Step 5: Cross-check against attestation
	result.SIPMatch = result.MDMSIPEnabled == attestationSIP
	result.SecureBootMatch = result.MDMSecureBootFull == attestationSecureBoot

	// A non-empty Error set below is a GENUINE posture failure proven by a
	// received SecurityInfo response — mark SecurityMismatch so the caller hard-
	// untrusts. (Transport/timeout/not-enrolled errors return above with
	// SecurityMismatch=false and must NOT untrust.)
	if !result.MDMSIPEnabled {
		result.Error = "MDM reports SIP disabled"
		result.SecurityMismatch = true
	} else if !result.MDMSecureBootFull {
		result.Error = "MDM reports Secure Boot not full"
		result.SecurityMismatch = true
	} else if !result.SIPMatch {
		result.Error = "attestation SIP does not match MDM SIP — provider may be lying"
		result.SecurityMismatch = true
	} else if !result.SecureBootMatch {
		result.Error = "attestation SecureBoot does not match MDM — provider may be lying"
		result.SecurityMismatch = true
	}
	// Recovery Lock is recommended but not enforced yet — log a warning.
	// When enforced, providers without Recovery Lock could enable RDMA via Recovery OS.
	// TODO: enforce once Recovery Lock is deployed to all provider machines.

	return result, nil
}
