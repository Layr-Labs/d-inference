package api

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"time"

	"github.com/coder/websocket"
	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/auth"
	"github.com/eigeninference/d-inference/coordinator/hardwareadmission"
	"github.com/eigeninference/d-inference/coordinator/mdm"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

const hardwareAdmissionStoreTimeout = 5 * time.Second

func (s *Server) initializeHardwareAdmission(cfg ServerConfig) {
	policy := hardwareadmission.DisabledPolicy()
	ctx, cancel := context.WithTimeout(context.Background(), hardwareAdmissionStoreTimeout)
	defer cancel()

	stored, err := s.store.GetActiveHardwareAdmissionPolicy(ctx)
	if err != nil {
		s.logger.Error("failed to load hardware admission policy; enforcement disabled",
			"error", err)
		s.setHardwareAdmissionPolicy(policy)
		return
	}
	if stored != nil {
		s.setHardwareAdmissionPolicy(*stored)
		return
	}

	rawMode := cfg.HardwareAdmissionMode
	if strings.TrimSpace(rawMode) == "" {
		rawMode = string(hardwareadmission.ModeDisabled)
	}
	mode, err := hardwareadmission.ParseMode(rawMode)
	if err != nil {
		s.logger.Error("invalid hardware admission bootstrap mode; enforcement disabled",
			"mode", cfg.HardwareAdmissionMode, "error", err)
		s.setHardwareAdmissionPolicy(policy)
		return
	}
	bootstrap := hardwareadmission.Policy{
		Mode: mode, CatalogVersion: hardwareadmission.CatalogVersion,
		MinMemoryGB:           cfg.HardwareAdmissionMinMemoryGB,
		MinMemoryBandwidthGBs: cfg.HardwareAdmissionMinBandwidthGBs,
		MinFP16MilliTFLOPS:    cfg.HardwareAdmissionMinFP16MilliTFLOPS,
		CreatedBy:             "environment", Reason: "bootstrap policy",
	}
	if err := bootstrap.Validate(); err != nil {
		s.logger.Error("invalid hardware admission bootstrap policy; enforcement disabled",
			"error", err)
		s.setHardwareAdmissionPolicy(policy)
		return
	}
	if mode == hardwareadmission.ModeDisabled &&
		bootstrap.MinMemoryGB == 0 &&
		bootstrap.MinMemoryBandwidthGBs == 0 &&
		bootstrap.MinFP16MilliTFLOPS == 0 {
		s.setHardwareAdmissionPolicy(policy)
		return
	}
	activated, err := s.store.ActivateHardwareAdmissionPolicy(ctx, bootstrap, 0)
	if err != nil {
		s.logger.Error("failed to persist hardware admission bootstrap policy; enforcement disabled",
			"error", err)
		s.setHardwareAdmissionPolicy(policy)
		return
	}
	s.setHardwareAdmissionPolicy(activated)
}

func (s *Server) setHardwareAdmissionPolicy(policy hardwareadmission.Policy) {
	if policy.CatalogVersion == "" {
		policy.CatalogVersion = hardwareadmission.CatalogVersion
	}
	s.hardwareAdmissionMu.Lock()
	s.hardwareAdmissionPolicy = policy
	s.hardwareAdmissionMu.Unlock()
	s.registry.SetHardwareAdmissionEnforced(policy.Mode == hardwareadmission.ModeEnforce)
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
	s.setHardwareAdmissionPolicy(*policy)
	return *policy, nil
}

func (s *Server) hardwareAdmissionEnforcing() bool {
	return s.hardwareAdmissionPolicySnapshot().Mode == hardwareadmission.ModeEnforce
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
		s.registry.SetProviderHardwareAdmitted(providerID, true)
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
			s.registry.SetProviderHardwareAdmitted(providerID, true)
			s.recordHardwareAdmissionAttempt(ctx, provider, serial, policy, "grandfathered", "", hardwareadmission.Decision{
				Allowed: true, MeetsThresholds: true,
				Observed: canonicalHardwareObserved(attestResult),
			})
			return true
		}
	}

	input := canonicalHardwareInput(attestResult)
	decision := hardwareadmission.Evaluate(policy, input)
	if mismatch := hardwareClaimMismatch(regMsg, attestResult); mismatch != "" {
		decision.MeetsThresholds = false
		decision.Allowed = policy.Mode != hardwareadmission.ModeEnforce
		decision.FailedChecks = append(decision.FailedChecks, hardwareadmission.Failure{
			Code: "hardware_claim_mismatch", Metric: mismatch, Unit: "exact match",
		})
	}
	if serial == "" {
		decision.MeetsThresholds = false
		decision.Allowed = policy.Mode != hardwareadmission.ModeEnforce
		decision.FailedChecks = append(decision.FailedChecks, hardwareadmission.Failure{
			Code: "hardware_identity_required", Metric: "serial_number", Unit: "attested identity",
		})
	}

	if policy.Mode == hardwareadmission.ModeShadow {
		s.registry.SetProviderHardwareAdmitted(providerID, true)
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
		return true
	}

	s.recordHardwareAdmissionAttempt(ctx, provider, serial, policy, "rejected", "hardware_below_minimum", decision)
	s.ddIncr("providers.hardware_admission", []string{"mode:enforce", "decision:rejected"})
	return s.rejectHardwareAdmission(provider, hardwareAdmissionRejection{
		code: "hardware_below_minimum", retryable: false, policy: policy,
		decision: &decision, reason: hardwareAdmissionReason(decision),
	})
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
	s.hardwareAdmissionPendingMu.Lock()
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
		provider.MDAVerified && provider.SEKeyBound &&
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
		s.logger.Warn("hardware admission finalization could not persist",
			"provider_id", provider.ID, "error", err)
		return false
	}
	s.registry.SetProviderHardwareAdmitted(provider.ID, true)
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

func (s *Server) handleProviderRequirements(w http.ResponseWriter, r *http.Request) {
	policy, err := s.refreshHardwareAdmissionPolicy(r.Context())
	if err != nil {
		writeJSON(w, http.StatusServiceUnavailable,
			errorResponse("admission_state_unavailable", "provider requirements are temporarily unavailable"))
		return
	}
	w.Header().Set("Cache-Control", "public, max-age=60")
	writeJSON(w, http.StatusOK, map[string]any{
		"policy":                  policy,
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
	if current.Mode == hardwareadmission.ModeEnforce && mode != hardwareadmission.ModeEnforce {
		writeJSON(w, http.StatusConflict,
			errorResponse("enforcement_rollback_forbidden", "an enforced hardware gate may only be replaced by another enforced policy"))
		return
	}
	actor := "admin-key"
	if user := auth.UserFromContext(r.Context()); user != nil {
		actor = user.Email
		if actor == "" {
			actor = user.AccountID
		}
	}
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
	s.setHardwareAdmissionPolicy(activated)
	s.reconcileConnectedHardwareAdmissions(activated)
	s.logger.Info("hardware admission policy activated",
		"version", activated.Version, "mode", activated.Mode,
		"grandfathered", activated.GrandfatheredProviderCount, "actor", actor)
	writeJSON(w, http.StatusOK, activated)
}

func (s *Server) reconcileConnectedHardwareAdmissions(policy hardwareadmission.Policy) {
	if policy.Mode != hardwareadmission.ModeEnforce {
		return
	}
	type candidate struct {
		id     string
		serial string
		input  hardwareadmission.Input
	}
	var candidates []candidate
	s.registry.ForEachProvider(func(provider *registry.Provider) {
		provider.Mu().Lock()
		provider.HardwareAdmitted = false
		if provider.AttestationResult != nil && provider.AttestationResult.Valid {
			family, tier, _ := hardwareadmission.ParseChipIdentity(
				provider.AttestationResult.ChipName)
			candidates = append(candidates, candidate{
				id: provider.ID, serial: provider.AttestationResult.SerialNumber,
				input: hardwareadmission.Input{
					MachineModel: provider.AttestationResult.HardwareModel,
					ChipName:     provider.AttestationResult.ChipName,
					ChipFamily:   family,
					ChipTier:     tier,
					MemoryGB:     provider.Hardware.MemoryGB,
					GPUCores:     provider.Hardware.GPUCores,
				},
			})
		}
		provider.Mu().Unlock()
	})
	for _, candidate := range candidates {
		ctx, cancel := context.WithTimeout(context.Background(), hardwareAdmissionStoreTimeout)
		admitted, err := s.store.IsHardwareAdmitted(ctx, candidate.serial)
		if err == nil && !admitted {
			decision := hardwareadmission.Evaluate(policy, candidate.input)
			if decision.Allowed && candidate.serial != "" {
				err = s.store.AdmitHardware(ctx, store.HardwareAdmission{
					SerialNumber: candidate.serial, Source: "policy",
					PolicyVersion: policy.Version, Hardware: decision.Observed,
					AdmittedAt: time.Now().UTC(),
				})
				admitted = err == nil
			}
		}
		cancel()
		s.registry.SetProviderHardwareAdmitted(candidate.id, err == nil && admitted)
	}
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
