package testbed

import (
	"fmt"
	"slices"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func (s *Suite) waitForProviderRegistration(timeout time.Duration) error {
	expectedCount := s.Config.TotalProviders()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if s.Coordinator.Registry.ProviderCount() >= expectedCount {
			break
		}
		time.Sleep(1 * time.Second)
	}
	if s.Coordinator.Registry.ProviderCount() < expectedCount {
		return fmt.Errorf("only %d/%d providers registered after %v", s.Coordinator.Registry.ProviderCount(), expectedCount, timeout)
	}
	if _, err := s.BoundProviders(); err != nil {
		return err
	}
	s.Logger.Info("providers registered", "count", s.Coordinator.Registry.ProviderCount())

	time.Sleep(3 * time.Second)

	return s.admitRegisteredProviders()
}

// admitRegisteredProviders captures wire evidence before granting synthetic test trust.
func (s *Suite) admitRegisteredProviders() error {
	// Snapshot each provider's self-reported privacy_capabilities BEFORE the
	// force-trust mutation below overwrites it; see privacyAtRegistration.
	snapshot := make(map[string]*protocol.PrivacyCapabilities)
	var ineligible string
	var capabilityProviderIDs []string

	// Force-trust all providers and link them to a user account so the
	// payout destination check passes when billing is enabled. Capability-aware
	// suites first validate the registration's hardware and runtime claims,
	// then grant the stronger test trust required by protected catalog models.
	s.Coordinator.Registry.ForEachProvider(func(p *registry.Provider) {
		p.Mu().Lock()
		defer p.Mu().Unlock()
		if reported := p.PrivacyCapabilities; reported != nil {
			copied := *reported
			snapshot[p.ID] = &copied
		} else {
			snapshot[p.ID] = nil
		}
		if len(s.Config.ExpectedProviderCapabilities) > 0 {
			if ineligible == "" {
				ineligible = providerCapabilityMismatch(p, s.Config.ExpectedProviderCapabilities)
			}
			if ineligible == "" {
				capabilityProviderIDs = append(capabilityProviderIDs, p.ID)
			}
		} else {
			p.TrustLevel = registry.TrustSelfSigned
		}
		p.Status = registry.StatusOnline
		p.ChallengeVerifiedSIP = true
		p.LastChallengeVerified = time.Now()
		p.FailedChallenges = 0
		p.RuntimeVerified = true
		p.RuntimeManifestChecked = true
		if p.PrivacyCapabilities == nil {
			p.PrivacyCapabilities = &protocol.PrivacyCapabilities{}
		}
		p.PrivacyCapabilities.TextBackendInprocess = true
		p.PrivacyCapabilities.TextProxyDisabled = true
		p.PrivacyCapabilities.PythonRuntimeLocked = true
		p.PrivacyCapabilities.DangerousModulesBlocked = true
		p.PrivacyCapabilities.AntiDebugEnabled = true
		p.PrivacyCapabilities.CoreDumpsDisabled = true
		p.PrivacyCapabilities.EnvScrubbed = true
		if p.AccountID == "" && len(s.Users) > 0 {
			p.AccountID = s.Users[0].AccountID
		}
	})
	if ineligible != "" {
		return fmt.Errorf("%w: %s", ErrProviderIneligible, ineligible)
	}
	for _, providerID := range capabilityProviderIDs {
		p := s.Coordinator.Registry.GetProvider(providerID)
		if p == nil {
			return fmt.Errorf("provider %s disconnected during capability admission", providerID)
		}
		p.SetAttested(true, registry.TrustHardware)
		p.SetFreshCodeAttested()
		p.Mu().Lock()
		p.RuntimeVerified = true
		p.RuntimeManifestChecked = true
		p.MetallibVerified = true
		p.Mu().Unlock()
		if err := s.Coordinator.Registry.ReconcileAttestedRuntimeCapabilities(providerID); err != nil {
			return fmt.Errorf("reconcile signed provider capabilities for %s: %w", providerID, err)
		}
		p.Mu().Lock()
		effective := append([]string(nil), p.RuntimeCapabilities...)
		p.Mu().Unlock()
		for _, required := range s.Config.ExpectedProviderCapabilities {
			if !slices.Contains(effective, required) {
				return fmt.Errorf(
					"signed capability reconciliation omitted %q for provider %s: %v",
					required, providerID, effective)
			}
		}
	}
	if len(s.Config.ExpectedProviderCapabilities) > 0 {
		models := s.Config.AllModelIDs()
		desired := make([]protocol.DesiredModelEntry, 0, len(models))
		covered := make(map[string]struct{}, len(s.Config.ModelAliases))
		for _, alias := range s.Config.ModelAliases {
			if !alias.Active {
				continue
			}
			desired = append(desired, protocol.DesiredModelEntry{
				ModelName: alias.AliasID, DesiredBuild: alias.DesiredBuild,
				PreviousBuild: alias.PreviousBuild,
			})
			covered[alias.DesiredBuild] = struct{}{}
			covered[alias.PreviousBuild] = struct{}{}
		}
		for _, model := range models {
			if _, ok := covered[model]; !ok {
				desired = append(desired, protocol.DesiredModelEntry{
					ModelName: model, DesiredBuild: model,
				})
			}
		}
		for _, providerID := range s.Coordinator.Registry.ProviderIDs() {
			if err := s.Coordinator.Registry.SendDesiredModels(providerID, desired); err != nil {
				return fmt.Errorf("refresh protected model inventory on provider %s: %w", providerID, err)
			}
		}
		deadline := time.Now().Add(60 * time.Second)
		for time.Now().Before(deadline) {
			snapshot := s.Coordinator.Registry.ModelProviderSnapshot()
			ready := true
			for _, model := range models {
				if snapshot[model] == 0 {
					ready = false
					break
				}
			}
			if ready {
				break
			}
			time.Sleep(250 * time.Millisecond)
		}
		snapshot := s.Coordinator.Registry.ModelProviderSnapshot()
		for _, model := range models {
			if snapshot[model] == 0 {
				return fmt.Errorf("protected model %q was not re-advertised after capability admission", model)
			}
		}
	}
	s.privacyMu.Lock()
	s.privacyAtRegistration = snapshot
	s.privacyMu.Unlock()
	s.Logger.Info("providers force-trusted for testing")

	return nil
}

// ReportedPrivacyCapabilities returns the privacy_capabilities block the
// given provider sent at registration, as captured before the testbed
// force-trusted the fleet. The returned pointer is a copy the caller may
// freely inspect; a nil block with ok==true means the provider registered
// and reported no privacy_capabilities at all, which is a real and
// distinguishable outcome. ok==false means no provider with that ID was
// present when the snapshot was taken.
//
// Assert against this, not against Registry state: the live registry copy
// has been overwritten with synthetic values by waitForProviderRegistration.
func (s *Suite) ReportedPrivacyCapabilities(providerID string) (*protocol.PrivacyCapabilities, bool) {
	s.privacyMu.Lock()
	defer s.privacyMu.Unlock()
	reported, ok := s.privacyAtRegistration[providerID]
	if !ok || reported == nil {
		return nil, ok
	}
	copied := *reported
	return &copied, true
}
