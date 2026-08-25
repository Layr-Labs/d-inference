package api

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/auth"
	"github.com/eigeninference/d-inference/coordinator/hardwareadmission"
	"github.com/eigeninference/d-inference/coordinator/mdm"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/saferun"
	"github.com/eigeninference/d-inference/coordinator/store"
	"nhooyr.io/websocket"
)

const hardwareAdmissionStoreTimeout = 5 * time.Second

func (s *Server) initializeHardwareAdmission(cfg ServerConfig) {
	policy := hardwareadmission.DisabledPolicy()
	ctx, cancel := context.WithTimeout(context.Background(), hardwareAdmissionStoreTimeout)
	defer cancel()

	stored, err := s.store.GetActiveHardwareAdmissionPolicy(ctx)
	if err != nil {
		s.logger.Error("failed to load hardware admission policy; registrations fail closed",
			"error", err)
		s.setHardwareAdmissionPolicy(hardwareadmission.Policy{
			Mode: hardwareadmission.ModeEnforce, CatalogVersion: hardwareadmission.CatalogVersion,
			Reason: "admission state unavailable",
		})
		if bootstrap, bootstrapErr := hardwareAdmissionBootstrapFromConfig(cfg); bootstrapErr == nil {
			s.scheduleHardwareAdmissionBootstrap(bootstrap)
		}
		return
	}
	if stored != nil {
		s.setHardwareAdmissionPolicy(*stored)
		return
	}

	bootstrap, err := hardwareAdmissionBootstrapFromConfig(cfg)
	if err != nil {
		s.logger.Error("invalid hardware admission bootstrap mode; registrations fail closed",
			"mode", cfg.HardwareAdmissionMode, "error", err)
		s.setHardwareAdmissionPolicy(hardwareadmission.Policy{
			Mode: hardwareadmission.ModeEnforce, CatalogVersion: hardwareadmission.CatalogVersion,
			Reason: "invalid admission bootstrap mode",
		})
		return
	}
	if bootstrap.Mode == hardwareadmission.ModeDisabled &&
		bootstrap.MinMemoryGB == 0 &&
		bootstrap.MinMemoryBandwidthGBs == 0 &&
		bootstrap.MinFP16MilliTFLOPS == 0 {
		s.setHardwareAdmissionPolicy(policy)
		return
	}
	activated, err := s.store.ActivateHardwareAdmissionPolicy(ctx, bootstrap, 0)
	if err != nil {
		s.logger.Error("failed to persist hardware admission bootstrap policy; registrations fail closed while retrying",
			"error", err)
		s.setHardwareAdmissionPolicy(hardwareadmission.Policy{
			Mode: hardwareadmission.ModeEnforce, CatalogVersion: hardwareadmission.CatalogVersion,
			Reason: "admission bootstrap persistence unavailable",
		})
		s.scheduleHardwareAdmissionBootstrap(bootstrap)
		return
	}
	s.setHardwareAdmissionPolicy(activated)
}

func hardwareAdmissionBootstrapFromConfig(cfg ServerConfig) (hardwareadmission.Policy, error) {
	rawMode := cfg.HardwareAdmissionMode
	if strings.TrimSpace(rawMode) == "" {
		rawMode = string(hardwareadmission.ModeDisabled)
	}
	mode, err := hardwareadmission.ParseMode(rawMode)
	if err != nil {
		return hardwareadmission.Policy{}, err
	}
	policy := hardwareadmission.Policy{
		Mode: mode, CatalogVersion: hardwareadmission.CatalogVersion,
		MinMemoryGB:           cfg.HardwareAdmissionMinMemoryGB,
		MinMemoryBandwidthGBs: cfg.HardwareAdmissionMinBandwidthGBs,
		MinFP16MilliTFLOPS:    cfg.HardwareAdmissionMinFP16MilliTFLOPS,
		CreatedBy:             "environment", Reason: "bootstrap policy",
	}
	if err := policy.ValidateForActivation(); err != nil {
		return hardwareadmission.Policy{}, err
	}
	return policy, nil
}

func (s *Server) scheduleHardwareAdmissionBootstrap(bootstrap hardwareadmission.Policy) {
	saferun.Go(s.logger, "hardwareAdmissionBootstrap", func() {
		for attempt := 1; ; attempt++ {
			delay := time.Duration(attempt) * 5 * time.Second
			if delay > time.Minute {
				delay = time.Minute
			}
			time.Sleep(delay)
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			active, err := s.store.GetActiveHardwareAdmissionPolicy(ctx)
			if err == nil && active != nil {
				cancel()
				_, reconcileErr := s.applyHardwareAdmissionPolicy(*active)
				if reconcileErr != nil {
					s.scheduleHardwareAdmissionReconciliation(*active)
				}
				return
			}
			if err == nil {
				var activated hardwareadmission.Policy
				activated, err = s.store.ActivateHardwareAdmissionPolicy(ctx, bootstrap, 0)
				if err == nil {
					cancel()
					_, reconcileErr := s.applyHardwareAdmissionPolicy(activated)
					if reconcileErr != nil {
						s.scheduleHardwareAdmissionReconciliation(activated)
					}
					return
				}
			}
			cancel()
			s.logger.Warn("hardware admission bootstrap retry failed",
				"attempt", attempt, "error", err)
		}
	})
}

func (s *Server) setHardwareAdmissionPolicy(policy hardwareadmission.Policy) bool {
	if policy.CatalogVersion == "" {
		policy.CatalogVersion = hardwareadmission.CatalogVersion
	}
	s.hardwareAdmissionMu.Lock()
	if policy.Version < s.hardwareAdmissionPolicy.Version {
		s.hardwareAdmissionMu.Unlock()
		return false
	}
	changed := s.hardwareAdmissionPolicy.Version != policy.Version ||
		s.hardwareAdmissionPolicy.Mode != policy.Mode
	s.hardwareAdmissionPolicy = policy
	s.hardwareAdmissionMu.Unlock()
	s.registry.SetHardwareAdmissionEnforced(policy.Mode == hardwareadmission.ModeEnforce)
	if changed {
		s.invalidateHardwareAdmissionCaches()
	}
	return true
}

func (s *Server) applyHardwareAdmissionPolicy(policy hardwareadmission.Policy) (bool, error) {
	s.hardwareAdmissionApplyMu.Lock()
	defer s.hardwareAdmissionApplyMu.Unlock()
	return s.applyHardwareAdmissionPolicyLocked(policy)
}

func (s *Server) applyHardwareAdmissionPolicyLocked(
	policy hardwareadmission.Policy,
) (bool, error) {
	current := s.hardwareAdmissionPolicySnapshot()
	if policy.Version == current.Version && policy.Mode == current.Mode {
		return true, nil
	}
	if !s.setHardwareAdmissionPolicy(policy) {
		return false, nil
	}
	return true, s.reconcileConnectedHardwareAdmissions(policy)
}

func (s *Server) liveTrustedHardwareAdmissions(
	policy hardwareadmission.Policy,
) []store.HardwareAdmission {
	bySerial := make(map[string]store.HardwareAdmission)
	s.registry.ForEachProvider(func(provider *registry.Provider) {
		provider.Mu().Lock()
		if provider.TrustLevel != registry.TrustHardware ||
			provider.AttestationResult == nil ||
			!provider.AttestationResult.Valid {
			provider.Mu().Unlock()
			return
		}
		result := *provider.AttestationResult
		hardware := provider.Hardware
		provider.Mu().Unlock()

		serial := strings.ToUpper(strings.TrimSpace(result.SerialNumber))
		if serial == "" {
			return
		}
		register := &protocol.RegisterMessage{Hardware: hardware}
		if _, failed := hardwareIdentityIntegrityFailure(register, result); failed {
			return
		}
		if legacySignedCapacityOmitted(result) {
			if hardware.MemoryGB <= 0 || hardware.GPUCores <= 0 {
				return
			}
			// Pre-capacity-attestation providers cannot sign RAM/GPU claims.
			// Grandfather their already-trusted live registration once, then
			// persist that canonical snapshot for every later reconnect.
			result.MemoryGB = hardware.MemoryGB
			result.GPUCores = hardware.GPUCores
		} else if _, failed := hardwareCapacityIntegrityFailure(register, result); failed {
			return
		}
		decision := evaluateHardwareClaims(
			policy, register, result)
		bySerial[serial] = store.HardwareAdmission{
			SerialNumber: serial,
			Source:       "grandfathered",
			Hardware:     decision.Observed,
		}
	})
	admissions := make([]store.HardwareAdmission, 0, len(bySerial))
	for _, admission := range bySerial {
		admissions = append(admissions, admission)
	}
	return admissions
}

func (s *Server) invalidateHardwareAdmissionCaches() {
	if s.readCache == nil {
		return
	}
	s.readCache.Invalidate("stats:v1")
	s.readCache.Invalidate("models_capacity:v1")
}

func (s *Server) hardwareAdmissionPolicySnapshot() hardwareadmission.Policy {
	s.hardwareAdmissionMu.RLock()
	defer s.hardwareAdmissionMu.RUnlock()
	return s.hardwareAdmissionPolicy
}

func (s *Server) refreshHardwareAdmissionPolicy(ctx context.Context) (hardwareadmission.Policy, error) {
	policy, err := s.store.GetActiveHardwareAdmissionPolicy(ctx)
	if err != nil {
		return hardwareadmission.Policy{}, err
	}
	if policy == nil {
		return s.hardwareAdmissionPolicySnapshot(), nil
	}
	applied, reconcileErr := s.applyHardwareAdmissionPolicy(*policy)
	if reconcileErr != nil {
		s.scheduleHardwareAdmissionReconciliation(*policy)
	}
	if !applied {
		return s.hardwareAdmissionPolicySnapshot(), nil
	}
	return *policy, nil
}

func (s *Server) hardwareAdmissionEnforcing() bool {
	return s.hardwareAdmissionPolicySnapshot().Mode == hardwareadmission.ModeEnforce
}

func (s *Server) validateHardwareAdmissionDependencies(
	policy hardwareadmission.Policy,
) error {
	if policy.Mode != hardwareadmission.ModeEnforce {
		return nil
	}
	if s.mdmClient == nil {
		return fmt.Errorf("enforce mode requires MicroMDM configuration")
	}
	if s.codeAttestor == nil {
		return fmt.Errorf("enforce mode requires APNs code-identity attestation")
	}
	return nil
}

// ValidateHardwareAdmissionReadiness is the startup gate for an active enforce
// policy. Admin activation calls the same dependency check before committing.
func (s *Server) ValidateHardwareAdmissionReadiness() error {
	policy := s.hardwareAdmissionPolicySnapshot()
	if err := policy.ValidateForActivation(); err != nil {
		return err
	}
	return s.validateHardwareAdmissionDependencies(policy)
}

func (s *Server) commitProviderAdmissionState(
	provider *registry.Provider,
	expected hardwareadmission.Policy,
	durableAdmission bool,
) bool {
	if provider == nil {
		return false
	}
	s.hardwareAdmissionApplyMu.Lock()
	defer s.hardwareAdmissionApplyMu.Unlock()
	return s.commitProviderAdmissionStateLocked(
		provider, expected, durableAdmission)
}

// commitProviderAdmissionStateLocked commits while the caller holds
// hardwareAdmissionApplyMu. Keeping the lock boundary explicit lets policy
// activation, reconciliation, revocation, and first admission serialize on one
// decision point.
func (s *Server) commitProviderAdmissionStateLocked(
	provider *registry.Provider,
	expected hardwareadmission.Policy,
	durableAdmission bool,
) bool {
	if provider == nil {
		return false
	}
	current := s.hardwareAdmissionPolicySnapshot()
	if current.Version != expected.Version || current.Mode != expected.Mode {
		return false
	}
	if current.Mode == hardwareadmission.ModeEnforce && !durableAdmission {
		return false
	}
	if !s.registry.CommitProviderHardwareAdmission(provider) {
		return false
	}
	if current.Mode != hardwareadmission.ModeEnforce &&
		!s.allowDuplicateProviderSerials {
		if result := provider.GetAttestationResult(); result != nil &&
			result.Valid && result.SerialNumber != "" {
			s.registry.DisconnectDuplicatesBySerial(
				provider, result.SerialNumber)
		}
	}
	return true
}

func (s *Server) grantProviderHardwareTrust(provider *registry.Provider) bool {
	if provider == nil {
		return false
	}
	s.hardwareAdmissionApplyMu.Lock()
	defer s.hardwareAdmissionApplyMu.Unlock()
	policy := s.hardwareAdmissionPolicySnapshot()
	if policy.Mode == hardwareadmission.ModeEnforce &&
		!provider.GetCodeAttested() {
		return false
	}
	// Before the first enforce cutoff, hardware trust and its durable provider
	// row must commit under the same policy-transition lock. Otherwise a
	// disconnect can remove the live provider before the async write lands and
	// activation will miss it from both grandfathering sources.
	ctx, cancel := context.WithTimeout(
		context.Background(), hardwareAdmissionStoreTimeout)
	granted, err := s.registry.GrantProviderHardwareAndPersistIfCurrent(
		ctx, provider, policy.Mode != hardwareadmission.ModeEnforce)
	cancel()
	if err != nil {
		s.logger.Warn("hardware trust persistence failed",
			"provider_id", provider.ID, "error", err)
		return false
	}
	return granted
}

func (s *Server) providerConnectionCurrent(provider *registry.Provider) bool {
	return provider != nil && s.registry.GetProvider(provider.ID) == provider
}

func (s *Server) admitProviderWithoutHardwareEvaluation(
	provider *registry.Provider,
) (hardwareadmission.Policy, bool, error) {
	for {
		ctx, cancel := context.WithTimeout(
			context.Background(), hardwareAdmissionStoreTimeout)
		policy, err := s.refreshHardwareAdmissionPolicy(ctx)
		cancel()
		if err != nil {
			return hardwareadmission.Policy{}, false, err
		}
		if policy.Mode == hardwareadmission.ModeEnforce {
			return policy, false, nil
		}
		if s.commitProviderAdmissionState(provider, policy, false) {
			return policy, true, nil
		}
		if !s.providerConnectionCurrent(provider) {
			return policy, false, nil
		}
	}
}

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
	if admitted.MemoryGB <= 0 || admitted.GPUCores <= 0 {
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
	decision := hardwareadmission.Evaluate(
		hardwareadmission.DisabledPolicy(),
		hardwareadmission.Input{
			MachineModel: admitted.MachineModel,
			ChipName:     admitted.ChipName,
			ChipFamily:   family,
			ChipTier:     tier,
			MemoryGB:     admitted.MemoryGB,
			GPUCores:     admitted.GPUCores,
		},
	)
	if !decision.Observed.CatalogKnown {
		return hardwareadmission.Observed{}, false
	}
	return decision.Observed, true
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

func canonicalHardwareObserved(result attestation.VerificationResult) hardwareadmission.Observed {
	return hardwareadmission.Evaluate(hardwareadmission.DisabledPolicy(), canonicalHardwareInput(result)).Observed
}

func hardwareClaimMismatch(regMsg *protocol.RegisterMessage, result attestation.VerificationResult) string {
	if mismatch := hardwareIdentityClaimMismatch(regMsg, result); mismatch != "" {
		return mismatch
	}
	return hardwareCapacityClaimMismatch(regMsg, result)
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
	if result.MemoryGB <= 0 || result.GPUCores <= 0 {
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

type hardwareAdmissionRejection struct {
	code      string
	reason    string
	retryable bool
	policy    hardwareadmission.Policy
	decision  *hardwareadmission.Decision
}

type pendingHardwareAdmission struct {
	provider *registry.Provider
	serial   string
	policy   hardwareadmission.Policy
	decision hardwareadmission.Decision
}

func (s *Server) stagePendingHardwareAdmission(providerID string, pending pendingHardwareAdmission) {
	if pending.provider == nil {
		pending.provider = s.registry.GetProvider(providerID)
	}
	s.hardwareAdmissionPendingMu.Lock()
	if pending.provider != nil &&
		!s.registry.SetProviderHardwareAdmitted(pending.provider, false) {
		s.hardwareAdmissionPendingMu.Unlock()
		return
	}
	if s.hardwareAdmissionPending == nil {
		s.hardwareAdmissionPending = make(map[string]pendingHardwareAdmission)
	}
	s.hardwareAdmissionPending[providerID] = pending
	s.hardwareAdmissionPendingMu.Unlock()
}

func (s *Server) hasPendingHardwareAdmission(providerID string) bool {
	s.hardwareAdmissionPendingMu.Lock()
	defer s.hardwareAdmissionPendingMu.Unlock()
	_, ok := s.hardwareAdmissionPending[providerID]
	return ok
}

func (s *Server) clearPendingHardwareAdmission(providerID string) {
	s.hardwareAdmissionPendingMu.Lock()
	delete(s.hardwareAdmissionPending, providerID)
	s.hardwareAdmissionPendingMu.Unlock()
}

func (s *Server) clearPendingHardwareAdmissionForProvider(provider *registry.Provider) {
	if provider == nil {
		return
	}
	s.hardwareAdmissionPendingMu.Lock()
	pending, ok := s.hardwareAdmissionPending[provider.ID]
	if ok && (pending.provider == nil || pending.provider == provider) {
		delete(s.hardwareAdmissionPending, provider.ID)
	}
	s.hardwareAdmissionPendingMu.Unlock()
}

func (s *Server) clearPendingHardwareAdmissionIf(
	providerID string,
	policyVersion int64,
	expectedProvider ...*registry.Provider,
) bool {
	s.hardwareAdmissionPendingMu.Lock()
	defer s.hardwareAdmissionPendingMu.Unlock()
	pending, ok := s.hardwareAdmissionPending[providerID]
	if !ok || pending.policy.Version != policyVersion {
		return false
	}
	if len(expectedProvider) > 0 && pending.provider != expectedProvider[0] {
		return false
	}
	delete(s.hardwareAdmissionPending, providerID)
	return true
}

func (s *Server) finalizePendingHardwareAdmission(provider *registry.Provider) bool {
	if provider == nil {
		return false
	}
	s.hardwareAdmissionPendingMu.Lock()
	pending, ok := s.hardwareAdmissionPending[provider.ID]
	s.hardwareAdmissionPendingMu.Unlock()
	if !ok {
		return provider.HardwareAdmissionStatus()
	}
	if pending.provider != nil && pending.provider != provider {
		return false
	}

	provider.Mu().Lock()
	var attestationResult attestation.VerificationResult
	if provider.AttestationResult != nil {
		attestationResult = *provider.AttestationResult
	}
	hardware := provider.Hardware
	identityReady := provider.TrustLevel == registry.TrustHardware &&
		provider.Status != registry.StatusUntrusted &&
		provider.MDAVerified && provider.MDAFreshnessVerified &&
		provider.CodeAttested &&
		provider.AttestationResult != nil &&
		strings.EqualFold(
			strings.TrimSpace(provider.AttestationResult.SerialNumber),
			strings.TrimSpace(pending.serial))
	provider.Mu().Unlock()
	if !identityReady {
		return false
	}

	ctx, cancel := context.WithTimeout(context.Background(), hardwareAdmissionStoreTimeout)
	defer cancel()
	policy, err := s.refreshHardwareAdmissionPolicy(ctx)
	if err != nil {
		s.logger.Warn("hardware admission finalization deferred",
			"provider_id", provider.ID, "error", err)
		return false
	}
	s.hardwareAdmissionPendingMu.Lock()
	currentPending, stillPending := s.hardwareAdmissionPending[provider.ID]
	stillPending = stillPending &&
		currentPending.policy.Version == pending.policy.Version &&
		(currentPending.provider == nil || currentPending.provider == provider)
	s.hardwareAdmissionPendingMu.Unlock()
	if !stillPending {
		return provider.HardwareAdmissionStatus()
	}
	s.hardwareAdmissionApplyMu.Lock()
	defer s.hardwareAdmissionApplyMu.Unlock()
	current := s.hardwareAdmissionPolicySnapshot()
	if current.Version != policy.Version || current.Mode != policy.Mode {
		return false
	}
	s.hardwareAdmissionPendingMu.Lock()
	currentPending, stillPending = s.hardwareAdmissionPending[provider.ID]
	stillPending = stillPending &&
		currentPending.policy.Version == pending.policy.Version &&
		(currentPending.provider == nil || currentPending.provider == provider)
	s.hardwareAdmissionPendingMu.Unlock()
	if !stillPending {
		return provider.HardwareAdmissionStatus()
	}
	if policy.Mode != hardwareadmission.ModeEnforce {
		if !s.commitProviderAdmissionStateLocked(provider, policy, false) {
			return false
		}
		return s.clearPendingHardwareAdmissionIf(
			provider.ID, pending.policy.Version, provider)
	}
	decision := pending.decision
	if policy.Version != pending.policy.Version {
		decision = evaluateHardwareClaims(
			policy,
			&protocol.RegisterMessage{Hardware: hardware},
			attestationResult,
		)
	}
	if policy.Mode == hardwareadmission.ModeEnforce && !decision.Allowed {
		if !s.clearPendingHardwareAdmissionIf(
			provider.ID, pending.policy.Version, provider) {
			return false
		}
		reasonCode := hardwareAdmissionReasonCode(decision)
		s.recordHardwareAdmissionAttempt(
			ctx, provider, pending.serial, policy, "rejected",
			reasonCode, decision)
		return s.rejectHardwareAdmission(provider, hardwareAdmissionRejection{
			code: reasonCode, retryable: false, policy: policy,
			decision: &decision, reason: hardwareAdmissionReason(decision),
		})
	}
	if err := s.store.AdmitHardware(ctx, store.HardwareAdmission{
		SerialNumber: pending.serial, Source: "policy", PolicyVersion: policy.Version,
		Hardware: decision.Observed, AdmittedAt: time.Now().UTC(),
	}); err != nil {
		if errors.Is(err, store.ErrHardwareAdmissionRevoked) {
			if !s.clearPendingHardwareAdmissionIf(
				provider.ID, pending.policy.Version, provider) {
				return false
			}
			s.registry.SetProviderHardwareRevoked(provider, true)
			return s.rejectHardwareAdmission(provider, hardwareAdmissionRejection{
				code: "hardware_admission_revoked", retryable: false, policy: policy,
				reason: "This machine's provider admission was revoked by a network operator.",
			})
		}
		s.logger.Warn("hardware admission finalization could not persist",
			"provider_id", provider.ID, "error", err)
		return false
	}
	if !s.clearPendingHardwareAdmissionIf(
		provider.ID, pending.policy.Version, provider) {
		return false
	}
	if !s.registry.CommitProviderHardwareAdmission(provider) {
		return false
	}
	s.invalidateHardwareAdmissionCaches()
	s.recordHardwareAdmissionAttempt(
		ctx, provider, pending.serial, policy, "admitted", "", decision)
	s.sendTrustStatus(
		provider, registry.TrustHardware, "online",
		"Hardware admission passed; provider is eligible for routing")
	s.ddIncr("providers.hardware_admission", []string{"mode:enforce", "decision:admitted"})
	s.registry.DrainQueuedRequestsForProvider(provider)
	return true
}

func (s *Server) schedulePendingHardwareAdmissionFinalization(provider *registry.Provider) {
	if provider == nil {
		return
	}
	s.hardwareAdmissionPendingMu.Lock()
	if s.hardwareAdmissionFinalizeRetry == nil {
		s.hardwareAdmissionFinalizeRetry = make(map[string]struct{})
	}
	if _, scheduled := s.hardwareAdmissionFinalizeRetry[provider.ID]; scheduled {
		s.hardwareAdmissionPendingMu.Unlock()
		return
	}
	s.hardwareAdmissionFinalizeRetry[provider.ID] = struct{}{}
	s.hardwareAdmissionPendingMu.Unlock()
	saferun.Go(s.logger, "hardwareAdmissionFinalize", func() {
		defer s.finishHardwareAdmissionFinalizationRetry(provider)
		for attempt := 1; ; attempt++ {
			delay := time.Duration(attempt) * 2 * time.Second
			if delay > 30*time.Second {
				delay = 30 * time.Second
			}
			time.Sleep(delay)
			if !s.hasPendingHardwareAdmission(provider.ID) ||
				s.registry.GetProvider(provider.ID) != provider {
				return
			}
			if s.finalizePendingHardwareAdmission(provider) {
				return
			}
		}
	})
}

func (s *Server) finishHardwareAdmissionFinalizationRetry(
	provider *registry.Provider,
) {
	if provider == nil {
		return
	}
	s.hardwareAdmissionPendingMu.Lock()
	delete(s.hardwareAdmissionFinalizeRetry, provider.ID)
	_, stillPending := s.hardwareAdmissionPending[provider.ID]
	s.hardwareAdmissionPendingMu.Unlock()
	if stillPending && s.registry.GetProvider(provider.ID) == provider {
		s.schedulePendingHardwareAdmissionFinalization(provider)
	}
}

func (s *Server) finalizeOrScheduleHardwareAdmission(provider *registry.Provider) {
	if provider == nil || !s.hasPendingHardwareAdmission(provider.ID) {
		return
	}
	if !s.finalizePendingHardwareAdmission(provider) {
		s.schedulePendingHardwareAdmissionFinalization(provider)
	}
}

func (s *Server) providerCodeIdentityReady(provider *registry.Provider) {
	if provider == nil || !provider.GetCodeAttested() {
		return
	}
	if result := provider.GetAttestationResult(); result != nil &&
		result.Valid && result.SerialNumber != "" &&
		!s.allowDuplicateProviderSerials {
		if s.hardwareAdmissionEnforcing() {
			if !s.registry.ClaimProviderSerial(provider, result.SerialNumber) {
				return
			}
		} else {
			s.registry.DisconnectDuplicatesBySerial(provider, result.SerialNumber)
		}
	}
	s.finalizeOrScheduleHardwareAdmission(provider)
}

func (s *Server) rejectHardwareAdmission(provider *registry.Provider, rejection hardwareAdmissionRejection) bool {
	if provider == nil {
		return false
	}
	s.registry.SetProviderHardwareAdmitted(provider, false)
	if rejection.code == "hardware_admission_revoked" {
		s.registry.SetProviderHardwareRevoked(provider, true)
	}
	s.clearPendingHardwareAdmissionForProvider(provider)
	retryable := rejection.retryable
	msg := protocol.TrustStatusMessage{
		Type: protocol.TypeTrustStatus, TrustLevel: string(registry.TrustNone),
		Status: "onboarding_rejected", Reason: rejection.reason,
		ReasonCode: rejection.code, PolicyVersion: rejection.policy.Version,
		CatalogVersion: rejection.policy.CatalogVersion, Retryable: &retryable,
	}
	if rejection.decision != nil {
		hw := trustStatusHardware(rejection.decision.Observed)
		msg.Hardware = &hw
		for _, failed := range rejection.decision.FailedChecks {
			msg.FailedChecks = append(msg.FailedChecks, protocol.TrustStatusRequirementMiss{
				Code: failed.Code, Metric: failed.Metric, Observed: failed.Observed,
				Required: failed.Required, Unit: failed.Unit,
			})
		}
	}
	data, err := json.Marshal(msg)
	if err == nil {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		err = provider.WriteTextControl(ctx, data)
		cancel()
	}
	if err != nil {
		s.logger.Warn("failed to deliver hardware admission rejection",
			"provider_id", provider.ID, "reason_code", rejection.code, "error", err)
	}
	s.logger.Warn("provider hardware admission rejected",
		"provider_id", provider.ID, "reason_code", rejection.code,
		"policy_version", rejection.policy.Version)
	if provider.Conn != nil {
		_ = provider.Conn.Close(websocket.StatusPolicyViolation, "provider hardware admission rejected")
	}
	return false
}

func trustStatusHardware(observed hardwareadmission.Observed) protocol.TrustStatusHardware {
	return protocol.TrustStatusHardware{
		MachineModel: observed.MachineModel, ChipName: observed.ChipName,
		ChipFamily: observed.ChipFamily, ChipTier: observed.ChipTier,
		MemoryGB: observed.MemoryGB, GPUCores: observed.GPUCores,
		MemoryBandwidthGBs: observed.MemoryBandwidthGBs,
		FP16MilliTFLOPS:    observed.FP16MilliTFLOPS, CatalogKnown: observed.CatalogKnown,
	}
}

func hardwareAdmissionReason(decision hardwareadmission.Decision) string {
	if len(decision.FailedChecks) == 0 {
		return "This Mac does not meet the current requirements for new providers."
	}
	parts := make([]string, 0, len(decision.FailedChecks))
	for _, failed := range decision.FailedChecks {
		switch failed.Code {
		case "hardware_not_catalogued":
			parts = append(parts, "this hardware SKU is not yet catalogued")
		case "hardware_claim_mismatch":
			parts = append(parts, "reported hardware does not match the attested machine")
		case "hardware_identity_required":
			parts = append(parts, "an attested machine identity is required")
		default:
			parts = append(parts, fmt.Sprintf("%s is %d %s (minimum %d %s)",
				failed.Metric, failed.Observed, failed.Unit, failed.Required, failed.Unit))
		}
	}
	return "This Mac does not meet the current requirements for new providers: " + strings.Join(parts, "; ") + ". Existing admitted machines are grandfathered."
}

type publicHardwareAdmissionPolicy struct {
	Version               int64                  `json:"version"`
	Mode                  hardwareadmission.Mode `json:"mode"`
	MinMemoryGB           int                    `json:"min_memory_gb"`
	MinMemoryBandwidthGBs int                    `json:"min_memory_bandwidth_gbs"`
	MinFP16MilliTFLOPS    int                    `json:"min_fp16_millitflops"`
	CatalogVersion        string                 `json:"catalog_version"`
	GrandfatherCutoffAt   *time.Time             `json:"grandfather_cutoff_at,omitempty"`
}

func (s *Server) handleProviderRequirements(w http.ResponseWriter, r *http.Request) {
	policy, err := s.refreshHardwareAdmissionPolicy(r.Context())
	if err != nil {
		writeJSON(w, http.StatusServiceUnavailable,
			errorResponse("admission_state_unavailable", "provider requirements are temporarily unavailable"))
		return
	}
	w.Header().Set("Cache-Control", "public, max-age=60")
	writeJSON(w, http.StatusOK, map[string]any{
		"policy": publicHardwareAdmissionPolicy{
			Version: policy.Version, Mode: policy.Mode,
			MinMemoryGB:           policy.MinMemoryGB,
			MinMemoryBandwidthGBs: policy.MinMemoryBandwidthGBs,
			MinFP16MilliTFLOPS:    policy.MinFP16MilliTFLOPS,
			CatalogVersion:        policy.CatalogVersion,
			GrandfatherCutoffAt:   policy.GrandfatherCutoffAt,
		},
		"accepting_new_providers": true,
		"grandfather_existing":    true,
		"metric_definitions": map[string]string{
			"memory_gb":            "installed unified memory in GiB",
			"memory_bandwidth_gbs": "coordinator-catalogued peak memory bandwidth in GB/s",
			"fp16_millitflops":     "estimated peak FP16 vector throughput in thousandths of a TFLOP",
		},
	})
}

func (s *Server) handleAdminHardwareAdmissionPolicy(w http.ResponseWriter, r *http.Request) {
	if !s.isAdminAuthorized(w, r) {
		return
	}
	switch r.Method {
	case http.MethodGet:
		policy, err := s.refreshHardwareAdmissionPolicy(r.Context())
		if err != nil {
			writeJSON(w, http.StatusInternalServerError,
				errorResponse("internal_error", "failed to load hardware admission policy"))
			return
		}
		writeJSON(w, http.StatusOK, policy)
	case http.MethodPut:
		s.handleAdminHardwareAdmissionPolicyPut(w, r)
	default:
		w.Header().Set("Allow", "GET, PUT")
		writeJSON(w, http.StatusMethodNotAllowed, errorResponse("method_not_allowed", "method not allowed"))
	}
}

func (s *Server) handleAdminHardwareAdmissionPolicyPut(w http.ResponseWriter, r *http.Request) {
	var req struct {
		Mode                   string `json:"mode"`
		MinMemoryGB            int    `json:"min_memory_gb"`
		MinMemoryBandwidthGBs  int    `json:"min_memory_bandwidth_gbs"`
		MinFP16MilliTFLOPS     int    `json:"min_fp16_millitflops"`
		Reason                 string `json:"reason"`
		ExpectedCurrentVersion int64  `json:"expected_current_version"`
		BreakGlass             bool   `json:"break_glass"`
	}
	if !decodeCappedJSON(w, r, maxControlPlaneBodyBytes, &req) {
		return
	}
	mode, err := hardwareadmission.ParseMode(req.Mode)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request", err.Error()))
		return
	}
	current, err := s.refreshHardwareAdmissionPolicy(r.Context())
	if err != nil {
		writeJSON(w, http.StatusInternalServerError,
			errorResponse("internal_error", "failed to load current hardware admission policy"))
		return
	}
	if req.ExpectedCurrentVersion != current.Version {
		writeJSON(w, http.StatusConflict,
			errorResponse("policy_version_conflict", "hardware admission policy changed; reload and retry"))
		return
	}
	if current.Mode == hardwareadmission.ModeEnforce &&
		mode != hardwareadmission.ModeEnforce &&
		(!req.BreakGlass || strings.TrimSpace(req.Reason) == "") {
		writeJSON(w, http.StatusConflict,
			errorResponse(
				"enforcement_rollback_requires_break_glass",
				"disabling an enforced hardware gate requires break_glass=true and a non-empty audit reason"))
		return
	}
	actor := hardwareAdmissionActor(r)
	policy := hardwareadmission.Policy{
		Mode: mode, MinMemoryGB: req.MinMemoryGB,
		MinMemoryBandwidthGBs: req.MinMemoryBandwidthGBs,
		MinFP16MilliTFLOPS:    req.MinFP16MilliTFLOPS,
		CatalogVersion:        hardwareadmission.CatalogVersion,
		CreatedBy:             actor, Reason: strings.TrimSpace(req.Reason),
	}
	if err := policy.ValidateForActivation(); err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request", err.Error()))
		return
	}
	if err := s.validateHardwareAdmissionDependencies(policy); err != nil {
		writeJSON(w, http.StatusConflict,
			errorResponse("hardware_admission_dependencies_unavailable", err.Error()))
		return
	}

	// Serialize the first enforcement transition with admission finalizers. The
	// live trusted snapshot and policy activation must be one transaction from
	// the control plane's perspective, or a trusted provider connected only in
	// memory can fall through the grandfathering cutoff.
	s.hardwareAdmissionApplyMu.Lock()
	defer s.hardwareAdmissionApplyMu.Unlock()
	var liveGrandfathered []store.HardwareAdmission
	if current.Mode != hardwareadmission.ModeEnforce &&
		mode == hardwareadmission.ModeEnforce {
		liveGrandfathered = s.liveTrustedHardwareAdmissions(policy)
	}
	activated, err := s.store.ActivateHardwareAdmissionPolicy(
		r.Context(), policy, req.ExpectedCurrentVersion, liveGrandfathered...)
	if err != nil {
		if errors.Is(err, store.ErrHardwareAdmissionPolicyConflict) {
			writeJSON(w, http.StatusConflict,
				errorResponse("policy_version_conflict", "hardware admission policy changed; reload and retry"))
			return
		}
		s.logger.Error("failed to activate hardware admission policy", "error", err)
		writeJSON(w, http.StatusInternalServerError,
			errorResponse("internal_error", "failed to activate hardware admission policy"))
		return
	}
	applied, reconcileErr := s.applyHardwareAdmissionPolicyLocked(activated)
	if !applied {
		writeJSON(w, http.StatusConflict,
			errorResponse("policy_version_conflict", "a newer hardware admission policy is already active"))
		return
	}
	if reconcileErr != nil {
		s.logger.Warn("hardware admission reconciliation will retry",
			"policy_version", activated.Version, "error", reconcileErr)
		s.scheduleHardwareAdmissionReconciliation(activated)
	}
	s.logger.Info("hardware admission policy activated",
		"version", activated.Version, "mode", activated.Mode,
		"grandfathered", activated.GrandfatheredProviderCount, "actor", actor)
	writeJSON(w, http.StatusOK, activated)
}

func (s *Server) scheduleHardwareAdmissionReconciliation(policy hardwareadmission.Policy) {
	s.hardwareAdmissionRetryMu.Lock()
	if s.hardwareAdmissionReconcileRetry == nil {
		s.hardwareAdmissionReconcileRetry = make(map[int64]struct{})
	}
	if _, scheduled := s.hardwareAdmissionReconcileRetry[policy.Version]; scheduled {
		s.hardwareAdmissionRetryMu.Unlock()
		return
	}
	s.hardwareAdmissionReconcileRetry[policy.Version] = struct{}{}
	s.hardwareAdmissionRetryMu.Unlock()
	saferun.Go(s.logger, "hardwareAdmissionReconcile", func() {
		defer func() {
			s.hardwareAdmissionRetryMu.Lock()
			delete(s.hardwareAdmissionReconcileRetry, policy.Version)
			s.hardwareAdmissionRetryMu.Unlock()
		}()
		for attempt := 1; ; attempt++ {
			delay := time.Duration(attempt) * 2 * time.Second
			if delay > 30*time.Second {
				delay = 30 * time.Second
			}
			time.Sleep(delay)
			s.hardwareAdmissionApplyMu.Lock()
			current := s.hardwareAdmissionPolicySnapshot()
			if current.Version != policy.Version || current.Mode != policy.Mode {
				s.hardwareAdmissionApplyMu.Unlock()
				return
			}
			err := s.reconcileConnectedHardwareAdmissions(policy)
			s.hardwareAdmissionApplyMu.Unlock()
			if err == nil {
				return
			}
		}
	})
}

func (s *Server) reconcileConnectedHardwareAdmissions(policy hardwareadmission.Policy) error {
	type candidate struct {
		provider *registry.Provider
		result   attestation.VerificationResult
		hardware protocol.Hardware
	}
	var candidates []candidate
	var unidentified []*registry.Provider
	s.registry.ForEachProvider(func(provider *registry.Provider) {
		provider.Mu().Lock()
		if policy.Mode == hardwareadmission.ModeEnforce {
			provider.HardwareAdmitted = false
		}
		if provider.AttestationResult != nil && provider.AttestationResult.Valid {
			result := *provider.AttestationResult
			candidates = append(candidates, candidate{
				provider: provider,
				result:   result,
				hardware: provider.Hardware,
			})
		} else {
			unidentified = append(unidentified, provider)
		}
		provider.Mu().Unlock()
	})
	for _, provider := range unidentified {
		if policy.Mode != hardwareadmission.ModeEnforce {
			s.registry.SetProviderHardwareAdmissionFence(provider, false, false)
			if s.registry.CommitProviderHardwareAdmission(provider) {
				s.clearPendingHardwareAdmission(provider.ID)
			}
			continue
		}
		s.rejectHardwareAdmission(provider, hardwareAdmissionRejection{
			code: "hardware_identity_missing", retryable: false, policy: policy,
			reason: "This provider did not supply a valid Secure Enclave hardware identity.",
		})
	}

	var firstErr error
	for _, candidate := range candidates {
		ctx, cancel := context.WithTimeout(context.Background(), hardwareAdmissionStoreTimeout)
		serial := strings.ToUpper(strings.TrimSpace(candidate.result.SerialNumber))
		if serial == "" {
			cancel()
			if policy.Mode != hardwareadmission.ModeEnforce {
				s.registry.SetProviderHardwareAdmissionFence(candidate.provider, false, false)
				if s.registry.CommitProviderHardwareAdmission(candidate.provider) {
					s.clearPendingHardwareAdmission(candidate.provider.ID)
				}
			} else {
				s.rejectHardwareAdmission(candidate.provider, hardwareAdmissionRejection{
					code: "hardware_identity_missing", retryable: false, policy: policy,
					reason: "This provider did not supply a stable hardware serial number.",
				})
			}
			continue
		}
		revoked, err := s.store.IsHardwareAdmissionRevoked(ctx, serial)
		cancel()
		if err != nil {
			s.registry.SetProviderHardwareAdmissionFence(candidate.provider, false, true)
			if firstErr == nil {
				firstErr = err
			}
			continue
		}
		if revoked {
			s.registry.SetProviderHardwareAdmissionFence(candidate.provider, true, false)
			decision := evaluateHardwareClaims(
				policy,
				&protocol.RegisterMessage{Hardware: candidate.hardware},
				candidate.result,
			)
			ctx, cancel = context.WithTimeout(context.Background(), hardwareAdmissionStoreTimeout)
			s.recordHardwareAdmissionAttempt(
				ctx, candidate.provider, serial, policy, "rejected",
				"hardware_admission_revoked", decision)
			cancel()
			s.rejectHardwareAdmission(candidate.provider, hardwareAdmissionRejection{
				code: "hardware_admission_revoked", retryable: false, policy: policy,
				reason: "This machine's provider admission was revoked by a network operator.",
			})
			continue
		}
		s.registry.SetProviderHardwareAdmissionFence(candidate.provider, false, false)
		if policy.Mode != hardwareadmission.ModeEnforce {
			if s.registry.CommitProviderHardwareAdmission(candidate.provider) {
				s.clearPendingHardwareAdmission(candidate.provider.ID)
			}
			continue
		}

		regMsg := &protocol.RegisterMessage{Hardware: candidate.hardware}
		decision := evaluateHardwareClaims(policy, regMsg, candidate.result)
		if failure, failed := hardwareIdentityIntegrityFailure(
			regMsg, candidate.result); failed {
			ctx, cancel = context.WithTimeout(
				context.Background(), hardwareAdmissionStoreTimeout)
			s.recordHardwareAdmissionAttempt(
				ctx, candidate.provider, serial, policy, "rejected",
				failure.Code, decision)
			cancel()
			s.rejectHardwareAdmission(
				candidate.provider, hardwareAdmissionRejection{
					code: failure.Code, retryable: false, policy: policy,
					decision: &decision, reason: hardwareIntegrityReason(failure),
				})
			continue
		}

		ctx, cancel = context.WithTimeout(context.Background(), hardwareAdmissionStoreTimeout)
		durableAdmission, err := s.store.GetHardwareAdmission(ctx, serial)
		cancel()
		if err != nil {
			if firstErr == nil {
				firstErr = err
			}
			continue
		}
		if durableAdmission != nil {
			if legacySignedCapacityOmitted(candidate.result) {
				hardware, ok := canonicalLegacyAdmissionHardware(
					durableAdmission.Hardware, candidate.result)
				if !ok {
					s.registry.SetProviderHardwareAdmissionFence(
						candidate.provider, false, true)
					if firstErr == nil {
						firstErr = errors.New(
							"legacy admission has no canonical hardware snapshot")
					}
					continue
				}
				if !s.registry.SetProviderHardwareFromAdmission(
					candidate.provider, hardware) {
					continue
				}
			} else if failure, failed := hardwareCapacityIntegrityFailure(
				regMsg, candidate.result); failed {
				ctx, cancel = context.WithTimeout(
					context.Background(), hardwareAdmissionStoreTimeout)
				s.recordHardwareAdmissionAttempt(
					ctx, candidate.provider, serial, policy, "rejected",
					failure.Code, decision)
				cancel()
				s.rejectHardwareAdmission(
					candidate.provider, hardwareAdmissionRejection{
						code: failure.Code, retryable: false, policy: policy,
						decision: &decision, reason: hardwareIntegrityReason(failure),
					})
				continue
			}
			s.registry.CommitProviderHardwareAdmission(candidate.provider)
			continue
		}

		if failure, failed := hardwareCapacityIntegrityFailure(
			regMsg, candidate.result); failed {
			ctx, cancel = context.WithTimeout(
				context.Background(), hardwareAdmissionStoreTimeout)
			s.recordHardwareAdmissionAttempt(
				ctx, candidate.provider, serial, policy, "rejected",
				failure.Code, decision)
			cancel()
			s.rejectHardwareAdmission(
				candidate.provider, hardwareAdmissionRejection{
					code: failure.Code, retryable: false, policy: policy,
					decision: &decision, reason: hardwareIntegrityReason(failure),
				})
			continue
		}
		if decision.Allowed {
			s.stagePendingHardwareAdmission(candidate.provider.ID, pendingHardwareAdmission{
				provider: candidate.provider, serial: serial,
				policy: policy, decision: decision,
			})
			s.schedulePendingHardwareAdmissionFinalization(candidate.provider)
			continue
		}
		ctx, cancel = context.WithTimeout(context.Background(), hardwareAdmissionStoreTimeout)
		reasonCode := hardwareAdmissionReasonCode(decision)
		s.recordHardwareAdmissionAttempt(
			ctx, candidate.provider, serial, policy, "rejected",
			reasonCode, decision)
		cancel()
		s.rejectHardwareAdmission(candidate.provider, hardwareAdmissionRejection{
			code: reasonCode, retryable: false, policy: policy,
			decision: &decision, reason: hardwareAdmissionReason(decision),
		})
	}
	return firstErr
}

func (s *Server) handleMyHardwareAdmissionAttempts(w http.ResponseWriter, r *http.Request) {
	user := s.requirePrivyUser(w, r)
	if user == nil {
		return
	}
	attempts, err := s.store.ListHardwareAdmissionAttempts(r.Context(), user.AccountID, 20)
	if err != nil {
		s.logger.Error("list hardware admission attempts failed", "error", err)
		writeJSON(w, http.StatusInternalServerError,
			errorResponse("internal_error", "failed to list provider admission attempts"))
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"attempts": attempts})
}

func (s *Server) handleAdminHardwareAdmissionMachines(w http.ResponseWriter, r *http.Request) {
	if !s.isAdminAuthorized(w, r) {
		return
	}
	admissions, err := s.store.ListHardwareAdmissions(r.Context(), 1000)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError,
			errorResponse("internal_error", "failed to list admitted provider machines"))
		return
	}
	attempts, err := s.store.ListHardwareAdmissionAttempts(r.Context(), "", 100)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError,
			errorResponse("internal_error", "failed to list provider admission attempts"))
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"admissions": admissions,
		"attempts":   attempts,
	})
}

func hardwareAdmissionActor(r *http.Request) string {
	if user := auth.UserFromContext(r.Context()); user != nil {
		if user.Email != "" {
			return user.Email
		}
		if user.AccountID != "" {
			return user.AccountID
		}
	}
	return "admin-key"
}

func (s *Server) handleAdminRevokeHardwareAdmission(w http.ResponseWriter, r *http.Request) {
	if !s.isAdminAuthorized(w, r) {
		return
	}
	serial := strings.ToUpper(strings.TrimSpace(r.PathValue("serial")))
	var req struct {
		Reason string `json:"reason"`
	}
	if !decodeCappedJSON(w, r, maxControlPlaneBodyBytes, &req) {
		return
	}
	req.Reason = strings.TrimSpace(req.Reason)
	if serial == "" || req.Reason == "" {
		writeJSON(w, http.StatusBadRequest,
			errorResponse("invalid_request", "serial and reason are required"))
		return
	}
	s.hardwareAdmissionApplyMu.Lock()
	defer s.hardwareAdmissionApplyMu.Unlock()
	if err := s.store.RevokeHardwareAdmission(
		r.Context(), serial, hardwareAdmissionActor(r), req.Reason); err != nil {
		if errors.Is(err, store.ErrNotFound) {
			writeJSON(w, http.StatusNotFound,
				errorResponse("not_found", "active hardware admission not found"))
			return
		}
		writeJSON(w, http.StatusInternalServerError,
			errorResponse("internal_error", "failed to revoke hardware admission"))
		return
	}
	var connected []*registry.Provider
	s.registry.ForEachProvider(func(provider *registry.Provider) {
		if result := provider.GetAttestationResult(); result != nil &&
			strings.EqualFold(strings.TrimSpace(result.SerialNumber), serial) {
			connected = append(connected, provider)
		}
	})
	policy := s.hardwareAdmissionPolicySnapshot()
	for _, provider := range connected {
		s.registry.SetProviderHardwareAdmissionFence(provider, true, false)
		result := provider.GetAttestationResult()
		if result != nil {
			provider.Mu().Lock()
			hardware := provider.Hardware
			provider.Mu().Unlock()
			decision := evaluateHardwareClaims(
				policy, &protocol.RegisterMessage{Hardware: hardware}, *result)
			s.recordHardwareAdmissionAttempt(
				r.Context(), provider, serial, policy, "rejected",
				"hardware_admission_revoked", decision)
		}
		s.rejectHardwareAdmission(provider, hardwareAdmissionRejection{
			code: "hardware_admission_revoked", retryable: false,
			policy: policy,
			reason: "This machine's provider admission was revoked by a network operator.",
		})
	}
	s.invalidateHardwareAdmissionCaches()
	writeJSON(w, http.StatusOK, map[string]any{
		"revoked": true, "serial_number": serial,
	})
}

func (s *Server) handleAdminRestoreHardwareAdmission(w http.ResponseWriter, r *http.Request) {
	if !s.isAdminAuthorized(w, r) {
		return
	}
	var req struct {
		SerialNumber string `json:"serial_number"`
		Reason       string `json:"reason"`
	}
	if !decodeCappedJSON(w, r, maxControlPlaneBodyBytes, &req) {
		return
	}
	req.SerialNumber = strings.ToUpper(strings.TrimSpace(req.SerialNumber))
	req.Reason = strings.TrimSpace(req.Reason)
	if req.SerialNumber == "" || req.Reason == "" {
		writeJSON(w, http.StatusBadRequest,
			errorResponse("invalid_request", "serial_number and reason are required"))
		return
	}
	s.hardwareAdmissionApplyMu.Lock()
	defer s.hardwareAdmissionApplyMu.Unlock()
	if err := s.store.RestoreHardwareAdmission(
		r.Context(), req.SerialNumber, hardwareAdmissionActor(r), req.Reason); err != nil {
		if errors.Is(err, store.ErrNotFound) {
			writeJSON(w, http.StatusNotFound,
				errorResponse("not_found", "revoked hardware admission not found"))
			return
		}
		writeJSON(w, http.StatusInternalServerError,
			errorResponse("internal_error", "failed to restore hardware admission"))
		return
	}
	s.invalidateHardwareAdmissionCaches()
	writeJSON(w, http.StatusOK, map[string]any{
		"restored": true, "serial_number": req.SerialNumber,
		"message": "The machine must reconnect and re-prove live identity before routing.",
	})
}
