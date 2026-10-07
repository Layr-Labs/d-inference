package testbed

import (
	"fmt"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
)

// bindAutopilotFixtureMachines supplies trusted identities only inside the
// isolated testbed, which skips Apple attestation. It does not prove hardware
// identity: the suite's own authenticated provider accounts select the fixtures.
// Inventory and desired mode use the real store; live control still requires
// the normal provider lease acknowledgement.
func (s *Suite) bindAutopilotFixtureMachines() ([]string, error) {
	if len(s.Providers) == 0 || len(s.Providers) != s.Config.TotalProviders() {
		return nil, fmt.Errorf("autopilot cohort requires all suite-owned providers")
	}
	byAccount := make(map[string]*registry.Provider, len(s.Providers))
	for _, handle := range s.Providers {
		if handle == nil || handle.AccountID == "" || !handle.Running() {
			return nil, fmt.Errorf("autopilot cohort requires running account-bound fixture providers")
		}
		if _, exists := byAccount[handle.AccountID]; exists {
			return nil, fmt.Errorf("autopilot cohort has duplicate fixture account %q", handle.AccountID)
		}
		byAccount[handle.AccountID] = nil
	}
	available, err := s.BoundProviders()
	if err != nil {
		return nil, fmt.Errorf("autopilot cohort provider binding: %w", err)
	}
	for _, p := range available {
		p.Mu().Lock()
		account := p.AccountID
		p.Mu().Unlock()
		if existing, owned := byAccount[account]; owned {
			if existing != nil {
				return nil, fmt.Errorf("autopilot cohort has multiple registered providers for fixture account %q", account)
			}
			byAccount[account] = p
		}
	}
	for _, handle := range s.Providers {
		if byAccount[handle.AccountID] == nil {
			return nil, fmt.Errorf("autopilot cohort has no registered provider for fixture account %q", handle.AccountID)
		}
	}
	inventory, ok := store.As[store.MachineInventoryStore](s.PgStore)
	if !ok {
		return nil, fmt.Errorf("autopilot fixture store has no machine inventory")
	}
	machines := make([]string, len(s.Providers))
	for i, handle := range s.Providers {
		credential, err := uuid.NewRandom()
		if err != nil {
			return nil, fmt.Errorf("autopilot fixture credential: %w", err)
		}
		p := byAccount[handle.AccountID]
		// Synthetic trusted evidence belongs only to this isolated fixture. The
		// real registration observer uses the same authenticated account/session;
		// its later ordinary observations must not replace the selected identity.
		machine, err := inventory.ObserveMachine(s.Ctx, store.MachineObservation{
			SessionID: p.ID, AccountID: handle.AccountID, RegisteredAt: p.RegisteredAt(),
			At: time.Now().UTC(), Source: "testbed_autopilot_fixture",
			VerifiedAppAttestKey: "testbed-autopilot-" + credential.String(),
		})
		if err != nil {
			return nil, fmt.Errorf("observe autopilot fixture machine for account %q: %w", handle.AccountID, err)
		}
		// No snapshot locks span store IO or binding. The production boundary
		// rechecks that this exact provider still owns the authenticated account.
		if !s.Coordinator.Registry.BindVerifiedMachineIdentity(p, handle.AccountID, machine.ID) {
			return nil, fmt.Errorf("autopilot fixture provider changed before machine binding for account %q", handle.AccountID)
		}
		if _, err := s.Coordinator.Registry.SetMachineAutopilotDesiredMode(s.Ctx, machine.ID, store.MachineAutopilotLive); err != nil {
			return nil, fmt.Errorf("select live autopilot fixture machine for account %q: %w", handle.AccountID, err)
		}
		machines[i] = machine.ID
	}
	return machines, nil
}
