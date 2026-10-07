package testbed

import (
	"fmt"
	"io"
	"log/slog"
	"strings"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/registry/autopilot"
	"github.com/google/uuid"
	"github.com/stretchr/testify/require"
)

func autopilotCohortTestSuite(t *testing.T) (*Suite, []*registry.Provider) {
	t.Helper()
	r := registry.New(slog.New(slog.NewTextHandler(io.Discard, nil)))
	s := &Suite{
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
			ids, err := s.bindAutopilotFixtureMachines()
			require.NoError(t, err)
			machines := strings.Split(ids, ",")
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

			cfg := autopilot.DefaultConfig()
			cfg.ObserveOnly, cfg.LiveMachineIDs = false, ids
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
		})
	}
}
