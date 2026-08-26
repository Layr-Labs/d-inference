package api

import (
	"context"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/hardwareadmission"
	"github.com/eigeninference/d-inference/coordinator/mdm"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func (s *Server) evaluateProviderHardwareAdmission(
	providerID string,
	provider *registry.Provider,
	regMsg *protocol.RegisterMessage,
	attestResult attestation.VerificationResult,
) bool {
	ctx, cancel := context.WithTimeout(context.Background(), hardwareAdmissionStoreTimeout)
	defer cancel()

	policy, err := s.refreshHardwareAdmissionPolicy(ctx)
	if err != nil {
		return s.rejectHardwareAdmission(provider, hardwareAdmissionRejection{
			code: "admission_state_unavailable", retryable: true,
			reason: "The coordinator could not verify provider admission state. It will retry automatically.",
		})
	}
	serial := ""
	if attestResult.Valid {
		serial = strings.ToUpper(strings.TrimSpace(attestResult.SerialNumber))
	}
	var durableAdmission *store.HardwareAdmission
	if serial != "" {
		durableAdmission, err = s.store.GetHardwareAdmission(ctx, serial)
		if err != nil {
			s.registry.SetProviderHardwareAdmissionFence(provider, false, true)
			return s.rejectHardwareAdmission(provider, hardwareAdmissionRejection{
				code: "admission_state_unavailable", retryable: true,
				policy: policy,
				reason: "The coordinator could not verify this machine's admission state. It will retry automatically.",
			})
		}
		if durableAdmission != nil && durableAdmission.RevokedAt != nil {
			s.registry.SetProviderHardwareAdmissionFence(provider, true, false)
			decision := evaluateHardwareClaims(policy, regMsg, attestResult)
			s.recordHardwareAdmissionAttempt(
				ctx, provider, serial, policy, "rejected",
				"hardware_admission_revoked", decision)
			return s.rejectHardwareAdmission(provider, hardwareAdmissionRejection{
				code: "hardware_admission_revoked", retryable: false, policy: policy,
				decision: &decision,
				reason:   "This machine's provider admission was revoked by a network operator.",
			})
		}
		s.registry.SetProviderHardwareAdmissionFence(provider, false, false)
	}
	if policy.Mode == hardwareadmission.ModeDisabled {
		if !s.commitProviderAdmissionState(provider, policy, false) {
			if !s.providerConnectionCurrent(provider) {
				return false
			}
			return s.evaluateProviderHardwareAdmission(
				providerID, provider, regMsg, attestResult)
		}
		return true
	}
	if failure, failed := hardwareIdentityIntegrityFailure(regMsg, attestResult); failed &&
		policy.Mode == hardwareadmission.ModeEnforce {
		return s.rejectHardwareClaimIntegrity(
			ctx, provider, serial, policy, attestResult, failure)
	}
	if durableAdmission != nil {
		if legacySignedCapacityOmitted(attestResult) {
			hardware, ok := canonicalLegacyAdmissionHardware(
				durableAdmission.Hardware, attestResult)
			if !ok {
				s.registry.SetProviderHardwareAdmissionFence(provider, false, true)
				return s.rejectHardwareAdmission(provider, hardwareAdmissionRejection{
					code: "admission_state_unavailable", retryable: true,
					policy: policy,
					reason: "The coordinator could not recover verified hardware for this legacy admission. It will retry automatically.",
				})
			}
			if !s.registry.SetProviderHardwareFromAdmission(provider, hardware) {
				return false
			}
		} else if failure, failed := hardwareCapacityIntegrityFailure(
			regMsg, attestResult); failed &&
			policy.Mode == hardwareadmission.ModeEnforce {
			return s.rejectHardwareClaimIntegrity(
				ctx, provider, serial, policy, attestResult, failure)
		}
		if !s.commitProviderAdmissionState(provider, policy, true) {
			if !s.providerConnectionCurrent(provider) {
				return false
			}
			return s.evaluateProviderHardwareAdmission(
				providerID, provider, regMsg, attestResult)
		}
		return true
	}
	if failure, failed := hardwareCapacityIntegrityFailure(
		regMsg, attestResult); failed &&
		policy.Mode == hardwareadmission.ModeEnforce {
		return s.rejectHardwareClaimIntegrity(
			ctx, provider, serial, policy, attestResult, failure)
	}

	// New admissions require a fresh signed hardware snapshot. Durable reconnects
	// returned above after exact identity/capacity validation (or a canonical
	// legacy-ledger fallback), so this does not fence grandfathered daemons.
	attestationAge := time.Since(attestResult.Timestamp)
	if attestResult.Timestamp.IsZero() ||
		attestationAge > 10*time.Minute ||
		attestationAge < -2*time.Minute {
		if policy.Mode == hardwareadmission.ModeEnforce {
			return s.rejectHardwareAdmission(provider, hardwareAdmissionRejection{
				code: "hardware_attestation_stale", retryable: false, policy: policy,
				reason: "The signed hardware attestation is stale or has an invalid timestamp. Restart the provider and try again.",
			})
		}
	}

	decision := evaluateHardwareClaims(policy, regMsg, attestResult)

	if policy.Mode == hardwareadmission.ModeShadow {
		if !s.commitProviderAdmissionState(provider, policy, false) {
			if !s.providerConnectionCurrent(provider) {
				return false
			}
			return s.evaluateProviderHardwareAdmission(
				providerID, provider, regMsg, attestResult)
		}
		outcome := "passed"
		reasonCode := ""
		if !decision.MeetsThresholds {
			outcome = "would_reject"
			reasonCode = hardwareAdmissionReasonCode(decision)
		}
		s.recordHardwareAdmissionAttempt(ctx, provider, serial, policy, outcome, reasonCode, decision)
		s.ddIncr("providers.hardware_admission", []string{"mode:shadow", "decision:" + outcome})
		return true
	}

	if decision.Allowed {
		s.stagePendingHardwareAdmission(providerID, pendingHardwareAdmission{
			provider: provider, serial: serial, policy: policy, decision: decision,
		})
		s.recordHardwareAdmissionAttempt(
			ctx, provider, serial, policy, "pending_identity", "", decision)
		s.ddIncr("providers.hardware_admission", []string{"mode:enforce", "decision:pending_identity"})
		s.finalizeOrScheduleHardwareAdmission(provider)
		return true
	}

	reasonCode := hardwareAdmissionReasonCode(decision)
	s.recordHardwareAdmissionAttempt(
		ctx, provider, serial, policy, "rejected", reasonCode, decision)
	s.ddIncr("providers.hardware_admission", []string{"mode:enforce", "decision:rejected"})
	return s.rejectHardwareAdmission(provider, hardwareAdmissionRejection{
		code: reasonCode, retryable: false, policy: policy,
		decision: &decision, reason: hardwareAdmissionReason(decision),
	})
}

func evaluateHardwareClaims(
	policy hardwareadmission.Policy,
	regMsg *protocol.RegisterMessage,
	attestResult attestation.VerificationResult,
) hardwareadmission.Decision {
	decision := hardwareadmission.Evaluate(policy, canonicalHardwareInput(attestResult))
	if failure, failed := hardwareClaimIntegrityFailure(regMsg, attestResult); failed {
		decision.MeetsThresholds = false
		decision.Allowed = policy.Mode != hardwareadmission.ModeEnforce
		decision.FailedChecks = append(decision.FailedChecks, failure)
	}
	return decision
}

func hardwareClaimIntegrityFailure(
	regMsg *protocol.RegisterMessage,
	result attestation.VerificationResult,
) (hardwareadmission.Failure, bool) {
	if failure, failed := hardwareIdentityIntegrityFailure(regMsg, result); failed {
		return failure, true
	}
	return hardwareCapacityIntegrityFailure(regMsg, result)
}

func hardwareIdentityIntegrityFailure(
	regMsg *protocol.RegisterMessage,
	result attestation.VerificationResult,
) (hardwareadmission.Failure, bool) {
	if strings.TrimSpace(result.SerialNumber) == "" {
		return hardwareadmission.Failure{
			Code: "hardware_identity_required", Metric: "serial_number",
			Unit: "attested identity",
		}, true
	}
	if strings.TrimSpace(result.HardwareModel) == "" {
		return hardwareadmission.Failure{
			Code: "hardware_identity_required", Metric: "machine_model",
			Unit: "attested identity",
		}, true
	}
	if strings.TrimSpace(result.ChipName) == "" {
		return hardwareadmission.Failure{
			Code: "hardware_identity_required", Metric: "chip_name",
			Unit: "attested identity",
		}, true
	}
	if mismatch := hardwareIdentityClaimMismatch(regMsg, result); mismatch != "" {
		return hardwareadmission.Failure{
			Code: "hardware_claim_mismatch", Metric: mismatch, Unit: "exact match",
		}, true
	}
	return hardwareadmission.Failure{}, false
}

func hardwareCapacityIntegrityFailure(
	regMsg *protocol.RegisterMessage,
	result attestation.VerificationResult,
) (hardwareadmission.Failure, bool) {
	if mismatch := hardwareCapacityClaimMismatch(regMsg, result); mismatch != "" {
		return hardwareadmission.Failure{
			Code: "hardware_claim_mismatch", Metric: mismatch, Unit: "exact match",
		}, true
	}
	return hardwareadmission.Failure{}, false
}

func (s *Server) rejectHardwareClaimIntegrity(
	ctx context.Context,
	provider *registry.Provider,
	serial string,
	policy hardwareadmission.Policy,
	result attestation.VerificationResult,
	failure hardwareadmission.Failure,
) bool {
	decision := hardwareadmission.Evaluate(
		policy, canonicalHardwareInput(result))
	decision.Allowed = false
	decision.MeetsThresholds = false
	decision.FailedChecks = append(decision.FailedChecks, failure)
	s.recordHardwareAdmissionAttempt(
		ctx, provider, serial, policy, "rejected", failure.Code, decision)
	return s.rejectHardwareAdmission(provider, hardwareAdmissionRejection{
		code: failure.Code, retryable: false, policy: policy,
		decision: &decision, reason: hardwareIntegrityReason(failure),
	})
}

func legacySignedCapacityOmitted(result attestation.VerificationResult) bool {
	return result.MemoryGB == 0 && result.GPUCores == 0
}

func canonicalLegacyAdmissionHardware(
	admitted hardwareadmission.Observed,
	result attestation.VerificationResult,
) (hardwareadmission.Observed, bool) {
	if admitted.MemoryGB <= 0 || admitted.GPUCores < 0 {
		return hardwareadmission.Observed{}, false
	}
	if admitted.MachineModel == "" {
		admitted.MachineModel = result.HardwareModel
	}
	if admitted.ChipName == "" {
		admitted.ChipName = result.ChipName
	}
	if !strings.EqualFold(
		strings.TrimSpace(admitted.MachineModel),
		strings.TrimSpace(result.HardwareModel)) ||
		!strings.EqualFold(
			strings.TrimSpace(admitted.ChipName),
			strings.TrimSpace(result.ChipName)) {
		return hardwareadmission.Observed{}, false
	}
	if capGB, known := mdm.ModelMaxMemoryGB(result.HardwareModel); known && capGB > 0 && admitted.MemoryGB > capGB {
		admitted.MemoryGB = capGB
	}
	family, tier, ok := hardwareadmission.ParseChipIdentity(result.ChipName)
	if !ok {
		return hardwareadmission.Observed{}, false
	}
	return hardwareadmission.Evaluate(
		hardwareadmission.DisabledPolicy(),
		hardwareadmission.Input{
			MachineModel: admitted.MachineModel,
			ChipName:     admitted.ChipName,
			ChipFamily:   family,
			ChipTier:     tier,
			MemoryGB:     admitted.MemoryGB,
			GPUCores:     admitted.GPUCores,
		},
	).Observed, true
}

func hardwareIntegrityReason(failure hardwareadmission.Failure) string {
	switch failure.Code {
	case "hardware_identity_required":
		return "A verified hardware identity is required before this machine can join the provider network."
	default:
		return "The advertised hardware does not match the signed hardware attestation."
	}
}

func hardwareAdmissionReasonCode(decision hardwareadmission.Decision) string {
	for _, failure := range decision.FailedChecks {
		switch failure.Code {
		case "hardware_claim_mismatch", "hardware_identity_required":
			return failure.Code
		}
	}
	return "hardware_below_minimum"
}

func canonicalHardwareInput(result attestation.VerificationResult) hardwareadmission.Input {
	memoryGB := result.MemoryGB
	if capGB, known := mdm.ModelMaxMemoryGB(result.HardwareModel); known && capGB > 0 && memoryGB > capGB {
		memoryGB = capGB
	}
	family, tier, _ := hardwareadmission.ParseChipIdentity(result.ChipName)
	return hardwareadmission.Input{
		MachineModel: result.HardwareModel,
		ChipName:     result.ChipName,
		ChipFamily:   family,
		ChipTier:     tier,
		MemoryGB:     memoryGB,
		GPUCores:     result.GPUCores,
	}
}

func hardwareIdentityClaimMismatch(
	regMsg *protocol.RegisterMessage,
	result attestation.VerificationResult,
) string {
	if !strings.EqualFold(strings.TrimSpace(result.HardwareModel), strings.TrimSpace(regMsg.Hardware.MachineModel)) {
		return "machine_model"
	}
	if !strings.EqualFold(strings.TrimSpace(result.ChipName), strings.TrimSpace(regMsg.Hardware.ChipName)) {
		return "chip_name"
	}
	family, tier, ok := hardwareadmission.ParseChipIdentity(result.ChipName)
	if ok && (!strings.EqualFold(family, regMsg.Hardware.ChipFamily) ||
		!strings.EqualFold(tier, regMsg.Hardware.ChipTier)) {
		return "chip_identity"
	}
	return ""
}

func hardwareCapacityClaimMismatch(
	regMsg *protocol.RegisterMessage,
	result attestation.VerificationResult,
) string {
	if result.MemoryGB <= 0 || result.GPUCores < 0 {
		return "attested_hardware"
	}
	if result.MemoryGB != regMsg.Hardware.MemoryGB {
		return "memory_gb"
	}
	if result.GPUCores != regMsg.Hardware.GPUCores {
		return "gpu_cores"
	}
	return ""
}

func (s *Server) recordHardwareAdmissionAttempt(
	ctx context.Context,
	provider *registry.Provider,
	serial string,
	policy hardwareadmission.Policy,
	outcome, reasonCode string,
	decision hardwareadmission.Decision,
) {
	provider.Mu().Lock()
	accountID := provider.AccountID
	provider.Mu().Unlock()
	if err := s.store.RecordHardwareAdmissionAttempt(ctx, store.HardwareAdmissionAttempt{
		ProviderID: provider.ID, SerialNumber: serial, AccountID: accountID,
		PolicyVersion: policy.Version, Mode: policy.Mode,
		Decision: outcome, ReasonCode: reasonCode,
		Hardware: decision.Observed, FailedChecks: decision.FailedChecks,
		CreatedAt: time.Now().UTC(),
	}); err != nil {
		s.logger.Warn("failed to record hardware admission attempt",
			"provider_id", provider.ID, "decision", outcome, "error", err)
	}
}
