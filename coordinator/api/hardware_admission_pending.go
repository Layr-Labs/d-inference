package api

import (
	"context"
	"errors"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/hardwareadmission"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/saferun"
	"github.com/eigeninference/d-inference/coordinator/store"
)

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
		len(provider.MDACertChain) > 0 &&
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
	snapshotPersisted, err :=
		s.registry.PersistPendingHardwareAdmissionSnapshotIfCurrent(ctx, provider)
	if err != nil {
		s.logger.Warn("hardware admission identity snapshot could not persist",
			"provider_id", provider.ID, "error", err)
		return false
	}
	if !snapshotPersisted {
		return false
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
