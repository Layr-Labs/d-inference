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
	if err := policy.Validate(); err != nil {
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
	current := s.hardwareAdmissionPolicySnapshot()
	if policy.Version == current.Version && policy.Mode == current.Mode {
		return true, nil
	}
	if !s.setHardwareAdmissionPolicy(policy) {
		return false, nil
	}
	return true, s.reconcileConnectedHardwareAdmissions(policy)
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
	current := s.hardwareAdmissionPolicySnapshot()
	if current.Version != expected.Version || current.Mode != expected.Mode {
		return false
	}
	if current.Mode == hardwareadmission.ModeEnforce && !durableAdmission {
		return false
	}
	s.registry.SetProviderHardwareAdmitted(provider.ID, true)
	s.registry.ActivateProviderPersistence(provider)
	if current.Mode != hardwareadmission.ModeEnforce &&
		!s.allowDuplicateProviderSerials {
		if result := provider.GetAttestationResult(); result != nil &&
			result.Valid && result.SerialNumber != "" {
			s.registry.DisconnectDuplicatesBySerial(
				provider.ID, result.SerialNumber)
		}
	}
	return true
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
	if policy.Mode == hardwareadmission.ModeDisabled {
		if !s.commitProviderAdmissionState(provider, policy, false) {
			return s.evaluateProviderHardwareAdmission(
				providerID, provider, regMsg, attestResult)
		}
		return true
	}
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

	serial := strings.ToUpper(strings.TrimSpace(attestResult.SerialNumber))
	if serial != "" {
		admitted, err := s.store.IsHardwareAdmitted(ctx, serial)
		if err != nil {
			return s.rejectHardwareAdmission(provider, hardwareAdmissionRejection{
				code: "admission_state_unavailable", retryable: true,
				policy: policy,
				reason: "The coordinator could not verify this machine's existing admission. It will retry automatically.",
			})
		}
		if admitted {
			if !s.commitProviderAdmissionState(provider, policy, true) {
				return s.evaluateProviderHardwareAdmission(
					providerID, provider, regMsg, attestResult)
			}
			s.recordHardwareAdmissionAttempt(ctx, provider, serial, policy, "grandfathered", "", hardwareadmission.Decision{
				Allowed: true, MeetsThresholds: true,
				Observed: canonicalHardwareObserved(attestResult),
			})
			return true
		}
	}

	decision := evaluateHardwareClaims(policy, regMsg, attestResult)

	if policy.Mode == hardwareadmission.ModeShadow {
		if !s.commitProviderAdmissionState(provider, policy, false) {
			return s.evaluateProviderHardwareAdmission(
				providerID, provider, regMsg, attestResult)
		}
		outcome := "passed"
		reasonCode := ""
		if !decision.MeetsThresholds {
			outcome = "would_reject"
			reasonCode = "hardware_below_minimum"
		}
		s.recordHardwareAdmissionAttempt(ctx, provider, serial, policy, outcome, reasonCode, decision)
		s.ddIncr("providers.hardware_admission", []string{"mode:shadow", "decision:" + outcome})
		return true
	}

	if decision.Allowed {
		s.stagePendingHardwareAdmission(providerID, pendingHardwareAdmission{
			serial: serial, policy: policy, decision: decision,
		})
		s.recordHardwareAdmissionAttempt(
			ctx, provider, serial, policy, "pending_identity", "", decision)
		s.ddIncr("providers.hardware_admission", []string{"mode:enforce", "decision:pending_identity"})
		s.finalizeOrScheduleHardwareAdmission(provider)
		return true
	}

	s.recordHardwareAdmissionAttempt(ctx, provider, serial, policy, "rejected", "hardware_below_minimum", decision)
	s.ddIncr("providers.hardware_admission", []string{"mode:enforce", "decision:rejected"})
	return s.rejectHardwareAdmission(provider, hardwareAdmissionRejection{
		code: "hardware_below_minimum", retryable: false, policy: policy,
		decision: &decision, reason: hardwareAdmissionReason(decision),
	})
}

func evaluateHardwareClaims(
	policy hardwareadmission.Policy,
	regMsg *protocol.RegisterMessage,
	attestResult attestation.VerificationResult,
) hardwareadmission.Decision {
	decision := hardwareadmission.Evaluate(policy, canonicalHardwareInput(attestResult))
	if mismatch := hardwareClaimMismatch(regMsg, attestResult); mismatch != "" {
		decision.MeetsThresholds = false
		decision.Allowed = policy.Mode != hardwareadmission.ModeEnforce
		decision.FailedChecks = append(decision.FailedChecks, hardwareadmission.Failure{
			Code: "hardware_claim_mismatch", Metric: mismatch, Unit: "exact match",
		})
	}
	if strings.TrimSpace(attestResult.SerialNumber) == "" {
		decision.MeetsThresholds = false
		decision.Allowed = policy.Mode != hardwareadmission.ModeEnforce
		decision.FailedChecks = append(decision.FailedChecks, hardwareadmission.Failure{
			Code: "hardware_identity_required", Metric: "serial_number", Unit: "attested identity",
		})
	}
	return decision
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
	if result.HardwareModel != "" && !strings.EqualFold(strings.TrimSpace(result.HardwareModel), strings.TrimSpace(regMsg.Hardware.MachineModel)) {
		return "machine_model"
	}
	if result.ChipName != "" && !strings.EqualFold(strings.TrimSpace(result.ChipName), strings.TrimSpace(regMsg.Hardware.ChipName)) {
		return "chip_name"
	}
	if result.MemoryGB <= 0 || result.GPUCores <= 0 {
		return "attested_hardware"
	}
	if result.MemoryGB != regMsg.Hardware.MemoryGB {
		return "memory_gb"
	}
	if result.GPUCores != regMsg.Hardware.GPUCores {
		return "gpu_cores"
	}
	family, tier, ok := hardwareadmission.ParseChipIdentity(result.ChipName)
	if ok && (!strings.EqualFold(family, regMsg.Hardware.ChipFamily) ||
		!strings.EqualFold(tier, regMsg.Hardware.ChipTier)) {
		return "chip_identity"
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
	serial   string
	policy   hardwareadmission.Policy
	decision hardwareadmission.Decision
}

func (s *Server) stagePendingHardwareAdmission(providerID string, pending pendingHardwareAdmission) {
	s.registry.SetProviderHardwareAdmitted(providerID, false)
	s.hardwareAdmissionPendingMu.Lock()
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

	provider.Mu().Lock()
	identityReady := provider.TrustLevel == registry.TrustHardware &&
		provider.MDAVerified && provider.SEKeyBound && provider.CodeAttested &&
		provider.AttestationResult != nil &&
		strings.EqualFold(provider.AttestationResult.SerialNumber, pending.serial)
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
	if policy.Mode != hardwareadmission.ModeEnforce {
		s.registry.SetProviderHardwareAdmitted(provider.ID, true)
		s.registry.ActivateProviderPersistence(provider)
		s.clearPendingHardwareAdmission(provider.ID)
		return true
	}
	decision := pending.decision
	if policy.Version != pending.policy.Version {
		decision = hardwareadmission.Evaluate(policy, hardwareadmission.Input{
			MachineModel: decision.Observed.MachineModel,
			ChipName:     decision.Observed.ChipName,
			ChipFamily:   decision.Observed.ChipFamily,
			ChipTier:     decision.Observed.ChipTier,
			MemoryGB:     decision.Observed.MemoryGB,
			GPUCores:     decision.Observed.GPUCores,
		})
	}
	if policy.Mode == hardwareadmission.ModeEnforce && !decision.Allowed {
		s.recordHardwareAdmissionAttempt(
			ctx, provider, pending.serial, policy, "rejected",
			"hardware_below_minimum", decision)
		s.clearPendingHardwareAdmission(provider.ID)
		return s.rejectHardwareAdmission(provider, hardwareAdmissionRejection{
			code: "hardware_below_minimum", retryable: false, policy: policy,
			decision: &decision, reason: hardwareAdmissionReason(decision),
		})
	}
	if err := s.store.AdmitHardware(ctx, store.HardwareAdmission{
		SerialNumber: pending.serial, Source: "policy", PolicyVersion: policy.Version,
		Hardware: decision.Observed, AdmittedAt: time.Now().UTC(),
	}); err != nil {
		if errors.Is(err, store.ErrHardwareAdmissionRevoked) {
			s.clearPendingHardwareAdmission(provider.ID)
			return s.rejectHardwareAdmission(provider, hardwareAdmissionRejection{
				code: "hardware_admission_revoked", retryable: false, policy: policy,
				reason: "This machine's provider admission was revoked by a network operator.",
			})
		}
		s.logger.Warn("hardware admission finalization could not persist",
			"provider_id", provider.ID, "error", err)
		return false
	}
	s.registry.SetProviderHardwareAdmitted(provider.ID, true)
	s.registry.ActivateProviderPersistence(provider)
	s.invalidateHardwareAdmissionCaches()
	s.recordHardwareAdmissionAttempt(
		ctx, provider, pending.serial, policy, "admitted", "", decision)
	s.clearPendingHardwareAdmission(provider.ID)
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
		defer func() {
			s.hardwareAdmissionPendingMu.Lock()
			delete(s.hardwareAdmissionFinalizeRetry, provider.ID)
			s.hardwareAdmissionPendingMu.Unlock()
		}()
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
			if !s.registry.ClaimProviderSerial(provider.ID, result.SerialNumber) {
				return
			}
		} else {
			s.registry.DisconnectDuplicatesBySerial(provider.ID, result.SerialNumber)
		}
	}
	s.finalizeOrScheduleHardwareAdmission(provider)
}

func (s *Server) rejectHardwareAdmission(provider *registry.Provider, rejection hardwareAdmissionRejection) bool {
	if provider == nil {
		return false
	}
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
	if err := policy.Validate(); err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse("invalid_request", err.Error()))
		return
	}
	activated, err := s.store.ActivateHardwareAdmissionPolicy(
		r.Context(), policy, req.ExpectedCurrentVersion)
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
	applied, reconcileErr := s.applyHardwareAdmissionPolicy(activated)
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
	if policy.Mode != hardwareadmission.ModeEnforce {
		s.registry.ForEachProvider(func(provider *registry.Provider) {
			s.registry.SetProviderHardwareAdmitted(provider.ID, true)
			s.registry.ActivateProviderPersistence(provider)
			s.clearPendingHardwareAdmission(provider.ID)
		})
		return nil
	}
	type candidate struct {
		provider *registry.Provider
		result   attestation.VerificationResult
		hardware protocol.Hardware
	}
	var candidates []candidate
	s.registry.ForEachProvider(func(provider *registry.Provider) {
		provider.Mu().Lock()
		provider.HardwareAdmitted = false
		if provider.AttestationResult != nil && provider.AttestationResult.Valid {
			result := *provider.AttestationResult
			candidates = append(candidates, candidate{
				provider: provider,
				result:   result,
				hardware: provider.Hardware,
			})
		}
		provider.Mu().Unlock()
	})
	var firstErr error
	for _, candidate := range candidates {
		ctx, cancel := context.WithTimeout(context.Background(), hardwareAdmissionStoreTimeout)
		serial := strings.ToUpper(strings.TrimSpace(candidate.result.SerialNumber))
		admitted, err := s.store.IsHardwareAdmitted(ctx, serial)
		cancel()
		if err != nil {
			if firstErr == nil {
				firstErr = err
			}
			continue
		}
		if admitted {
			s.registry.SetProviderHardwareAdmitted(candidate.provider.ID, true)
			s.registry.ActivateProviderPersistence(candidate.provider)
			continue
		}

		regMsg := &protocol.RegisterMessage{Hardware: candidate.hardware}
		decision := evaluateHardwareClaims(policy, regMsg, candidate.result)
		if decision.Allowed {
			s.stagePendingHardwareAdmission(candidate.provider.ID, pendingHardwareAdmission{
				serial: serial, policy: policy, decision: decision,
			})
			s.schedulePendingHardwareAdmissionFinalization(candidate.provider)
			continue
		}
		ctx, cancel = context.WithTimeout(context.Background(), hardwareAdmissionStoreTimeout)
		s.recordHardwareAdmissionAttempt(
			ctx, candidate.provider, serial, policy, "rejected",
			"hardware_below_minimum", decision)
		cancel()
		s.rejectHardwareAdmission(candidate.provider, hardwareAdmissionRejection{
			code: "hardware_below_minimum", retryable: false, policy: policy,
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
			strings.EqualFold(result.SerialNumber, serial) {
			connected = append(connected, provider)
		}
	})
	for _, provider := range connected {
		s.registry.SetProviderHardwareAdmitted(provider.ID, false)
		s.rejectHardwareAdmission(provider, hardwareAdmissionRejection{
			code: "hardware_admission_revoked", retryable: false,
			policy: s.hardwareAdmissionPolicySnapshot(),
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
