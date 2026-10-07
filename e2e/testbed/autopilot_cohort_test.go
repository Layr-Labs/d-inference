package testbed

import (
	"fmt"
	"io"
	"log/slog"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/registry/autopilot"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/google/uuid"
	"github.com/stretchr/testify/require"
)

func autopilotCohortTestSuite(t *testing.T) (*Suite, []*registry.Provider) {
	t.Helper()
	r := registry.New(slog.New(slog.NewTextHandler(io.Discard, nil)))
	st := NewMemoryStore()
	r.SetStore(st)
	s := &Suite{
		Ctx:         t.Context(),
		PgStore:     st,
		Config:      SuiteConfig{Autopilot: true, ModelSpecs: []ModelSpec{{ModelID: "cached-model", NumProviders: 2}}},
		Coordinator: &Coordinator{Registry: r},
		// These handles stand in for successful testbed process launches. The
		// registry and its identity/cohort authority below are the real owners.
		Providers: []*Provider{
			{AccountID: "testbed-provider-0", done: make(chan struct{})},
			{AccountID: "testbed-provider-1", done: make(chan struct{})},
		},
	}
	accounts := []string{s.Providers[0].AccountID, s.Providers[1].AccountID, "testbed-provider-unowned"}
	registered := make([]*registry.Provider, len(accounts))
	for i := len(accounts) - 1; i >= 0; i-- {
		p := r.Register(fmt.Sprintf("connection-%d", i), nil, &protocol.RegisterMessage{
			ModelAutopilot: &protocol.ModelAutopilotState{
				Protocol: protocol.ModelAutopilotProtocol, Enabled: true, CachedOnly: true,
				Revision: "testbed-autopilot", SelectedModels: []string{"cached-model"},
			},
		})
		// Seed only the authenticated account outcome normally set by the API;
		// the fixture binder must not manufacture or replace account ownership.
		p.Mu().Lock()
		p.AccountID = accounts[i]
		p.Mu().Unlock()
		registered[i] = p
	}
	return s, registered
}

func TestAutopilotFixtureMachinesSelectOnlyOwnedAccounts(t *testing.T) {
	for _, targets := range []bool{false, true} {
		t.Run(fmt.Sprintf("owned_targets=%t", targets), func(t *testing.T) {
			s, registered := autopilotCohortTestSuite(t)
			if targets {
				s.Config.ProviderTargets = []ProviderTarget{{Name: "a"}, {Name: "b"}}
				for i, handle := range s.Providers {
					handle.Target = &s.Config.ProviderTargets[i]
					handle.owned = &ownedProvider{hostID: fmt.Sprintf("physical-%d", i), done: make(chan struct{})}
				}
			}
			machines, err := s.bindAutopilotFixtureMachines()
			require.NoError(t, err)
			require.Len(t, machines, len(s.Providers))
			require.NotEqual(t, machines[0], machines[1])
			for i, handle := range s.Providers {
				machine, err := uuid.Parse(machines[i])
				require.NoError(t, err)
				require.NotEqual(t, uuid.Nil, machine)
				require.Equal(t, machine.String(), machines[i])
				account, boundMachine := registered[i].GetVerifiedMachineIdentity()
				require.Equal(t, handle.AccountID, account)
				require.Equal(t, machines[i], boundMachine)
			}
			account, machine := registered[2].GetVerifiedMachineIdentity()
			require.Empty(t, account, "an unowned provider must not acquire fixture trust")
			require.Empty(t, machine)
			settings, ok := store.As[store.MachineAutopilotStore](s.PgStore)
			require.True(t, ok)
			live, err := settings.LiveMachineAutopilotSettings(s.Ctx)
			require.NoError(t, err)
			require.ElementsMatch(t, []store.MachineAutopilotSetting{
				{MachineID: machines[0], DesiredMode: store.MachineAutopilotLive, Revision: 1},
				{MachineID: machines[1], DesiredMode: store.MachineAutopilotLive, Revision: 1},
			}, live)

			cfg := autopilot.DefaultConfig()
			cfg.ObserveOnly = false
			require.NoError(t, s.Coordinator.Registry.ConfigureAutopilot(cfg))
			summary := s.Coordinator.Registry.TriggerAutopilot()
			require.Equal(t, 2, summary.LiveCohort)
			require.Equal(t, 1, summary.Shadow)
			require.Zero(t, summary.LiveActive, "fixture identity is not a live-lease acknowledgement")
			require.Zero(t, summary.Issued)
		})
	}
}

func TestAutopilotFixtureMachinesRejectOwnershipMismatch(t *testing.T) {
	for _, problem := range []string{"missing handle", "empty account", "missing registration", "duplicate registration", "duplicate handle", "stopped process", "unowned target", "offline provider"} {
		t.Run(problem, func(t *testing.T) {
			s, registered := autopilotCohortTestSuite(t)
			switch problem {
			case "missing handle":
				s.Providers = s.Providers[:1]
			case "empty account":
				s.Providers[1].AccountID = ""
			case "missing registration":
				registered[1].Mu().Lock()
				registered[1].AccountID = "another-account"
				registered[1].Mu().Unlock()
			case "duplicate registration":
				registered[2].Mu().Lock()
				registered[2].AccountID = s.Providers[0].AccountID
				registered[2].Mu().Unlock()
			case "duplicate handle":
				s.Providers[1] = s.Providers[0]
			case "stopped process":
				close(s.Providers[1].done)
			case "unowned target":
				s.Config.ProviderTargets = []ProviderTarget{{Name: "a"}, {Name: "b"}}
				for i, handle := range s.Providers {
					handle.Target = &s.Config.ProviderTargets[i]
				}
			case "offline provider":
				registered[0].Mu().Lock()
				registered[0].Status = registry.StatusOffline
				registered[0].Mu().Unlock()
			}
			ids, err := s.bindAutopilotFixtureMachines()
			require.Error(t, err)
			require.Empty(t, ids, "a mismatched fixture cannot configure a live cohort")
			for _, p := range registered {
				account, machine := p.GetVerifiedMachineIdentity()
				require.Empty(t, account)
				require.Empty(t, machine)
			}
			settings, ok := store.As[store.MachineAutopilotStore](s.PgStore)
			require.True(t, ok)
			live, err := settings.LiveMachineAutopilotSettings(s.Ctx)
			require.NoError(t, err)
			require.Empty(t, live, "ownership failure must not persist live selection")
		})
	}
}

func TestAutopilotFixtureMachinesPreserveRegistrationIdentityAndDesiredMode(t *testing.T) {
	for _, observedFirst := range []bool{false, true} {
		t.Run(fmt.Sprintf("registration_observed_first=%t", observedFirst), func(t *testing.T) {
			s, registered := autopilotCohortTestSuite(t)
			inventory, ok := store.As[store.MachineInventoryStore](s.PgStore)
			require.True(t, ok)
			observation := store.MachineObservation{
				SessionID: registered[0].ID, AccountID: s.Providers[0].AccountID,
				SEKey: "fixture-registration-key", Source: "live_registration", At: time.Now().UTC(),
			}
			var initial store.MachineIdentity
			var err error
			if observedFirst {
				initial, err = inventory.ObserveMachine(s.Ctx, observation)
				require.NoError(t, err)
			}
			machines, err := s.bindAutopilotFixtureMachines()
			require.NoError(t, err)
			if observedFirst {
				require.Equal(t, initial.ID, machines[0])
			}
			observation.At = time.Now().UTC()
			observed, err := inventory.ObserveMachine(s.Ctx, observation)
			require.NoError(t, err)
			require.Equal(t, machines[0], observed.ID)
			settings, ok := store.As[store.MachineAutopilotStore](s.PgStore)
			require.True(t, ok)
			live, err := settings.LiveMachineAutopilotSettings(s.Ctx)
			require.NoError(t, err)
			require.Contains(t, live, store.MachineAutopilotSetting{
				MachineID: machines[0], DesiredMode: store.MachineAutopilotLive, Revision: 1,
			})
		})
	}
}

func TestAutopilotFixtureMachinesRejectInventoryOwnerConflict(t *testing.T) {
	for _, account := range []string{"", "different-owner"} {
		t.Run(fmt.Sprintf("inventory_account=%q", account), func(t *testing.T) {
			s, registered := autopilotCohortTestSuite(t)
			inventory, ok := store.As[store.MachineInventoryStore](s.PgStore)
			require.True(t, ok)
			_, err := inventory.ObserveMachine(s.Ctx, store.MachineObservation{
				SessionID: registered[0].ID, AccountID: account,
				Source: "live_registration", At: time.Now().UTC(),
			})
			require.NoError(t, err)
			machines, err := s.bindAutopilotFixtureMachines()
			require.ErrorContains(t, err, "machine_session_owner_conflict")
			require.Empty(t, machines)
			for _, p := range registered {
				account, machine := p.GetVerifiedMachineIdentity()
				require.Empty(t, account)
				require.Empty(t, machine)
			}
			settings, ok := store.As[store.MachineAutopilotStore](s.PgStore)
			require.True(t, ok)
			live, err := settings.LiveMachineAutopilotSettings(s.Ctx)
			require.NoError(t, err)
			require.Empty(t, live)
		})
	}
}
