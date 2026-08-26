package api

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/eigeninference/d-inference/coordinator/hardwareadmission"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/saferun"
	"github.com/eigeninference/d-inference/coordinator/store"
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
			if hardware.MemoryGB <= 0 || hardware.GPUCores < 0 {
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
