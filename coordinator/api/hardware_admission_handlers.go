package api

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/auth"
	"github.com/eigeninference/d-inference/coordinator/hardwareadmission"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"nhooyr.io/websocket"
)

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
