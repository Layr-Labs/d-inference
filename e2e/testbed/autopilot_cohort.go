package testbed

import (
	"fmt"
	"strings"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/google/uuid"
)

// bindAutopilotFixtureMachines supplies trusted identities only inside the
// isolated testbed, which skips Apple attestation. It does not prove hardware
// identity: the suite's own authenticated provider accounts select the fixtures.
// Live control still requires the normal provider lease acknowledgement.
func (s *Suite) bindAutopilotFixtureMachines() (string, error) {
	if len(s.Providers) == 0 || len(s.Providers) != s.Config.TotalProviders() {
		return "", fmt.Errorf("autopilot cohort requires all suite-owned providers")
	}
	byAccount := make(map[string]*registry.Provider, len(s.Providers))
	for _, handle := range s.Providers {
		if handle == nil || handle.AccountID == "" || !handle.Running() {
			return "", fmt.Errorf("autopilot cohort requires running account-bound fixture providers")
		}
		if _, exists := byAccount[handle.AccountID]; exists {
			return "", fmt.Errorf("autopilot cohort has duplicate fixture account %q", handle.AccountID)
		}
		byAccount[handle.AccountID] = nil
	}
	available, err := s.BoundProviders()
	if err != nil {
		return "", fmt.Errorf("autopilot cohort provider binding: %w", err)
	}
	for _, p := range available {
		p.Mu().Lock()
		account := p.AccountID
		p.Mu().Unlock()
		if existing, owned := byAccount[account]; owned {
			if existing != nil {
				return "", fmt.Errorf("autopilot cohort has multiple registered providers for fixture account %q", account)
			}
			byAccount[account] = p
		}
	}
	machines := make([]string, len(s.Providers))
	for i, handle := range s.Providers {
		if byAccount[handle.AccountID] == nil {
			return "", fmt.Errorf("autopilot cohort has no registered provider for fixture account %q", handle.AccountID)
		}
		machine, err := uuid.NewRandom()
		if err != nil {
			return "", fmt.Errorf("autopilot fixture machine identity: %w", err)
		}
		machines[i] = machine.String()
	}
	// Bind outside snapshot locks: the production boundary rechecks the exact
	// current provider and account under its own registry/provider locks.
	for i, handle := range s.Providers {
		if !s.Coordinator.Registry.BindVerifiedMachineIdentity(byAccount[handle.AccountID], handle.AccountID, machines[i]) {
			return "", fmt.Errorf("autopilot fixture provider changed before machine binding for account %q", handle.AccountID)
		}
	}
	return strings.Join(machines, ","), nil
}
