package operations_test

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry/autopilot"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

func TestAutopilotMachinesDesiredModeDoesNotImplyActiveControl(t *testing.T) {
	for _, tc := range []struct {
		name, effectiveMode                              string
		unconfigured, disabled, observeOnly              bool
		globalPaused, providerPaused, private, noConsent bool
	}{
		{name: "unconfigured", effectiveMode: "disabled", unconfigured: true},
		{name: "disabled", effectiveMode: "disabled", disabled: true},
		{name: "global shadow", effectiveMode: "shadow", observeOnly: true},
		{name: "global pause", effectiveMode: "paused", globalPaused: true},
		{name: "provider pause", effectiveMode: "paused", providerPaused: true},
		{name: "private", effectiveMode: "private", private: true},
		{name: "unconsented", effectiveMode: "unconsented", noConsent: true},
		{name: "awaiting acknowledgement", effectiveMode: "awaiting_ack"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			st := memory.NewMemory(store.Config{})
			reg, _, server := newAutopilotMachineHTTP(t, st)
			id := observeAutopilotMachine(t, st, "verified-provider")
			if !tc.unconfigured {
				cfg := autopilot.DefaultConfig()
				cfg.Enabled, cfg.ObserveOnly = !tc.disabled, tc.observeOnly
				if err := reg.ConfigureAutopilot(cfg); err != nil {
					t.Fatal(err)
				}
			}
			if tc.globalPaused && !reg.SetAutopilotPaused(true) {
				t.Fatal("controller pause rejected")
			}
			var state *protocol.ModelAutopilotState
			if !tc.noConsent {
				state = &protocol.ModelAutopilotState{
					Protocol: protocol.ModelAutopilotProtocol, Enabled: true, CachedOnly: true,
					Revision: "private-consent-revision", SessionID: "private-consent-session",
					SelectedModels: []string{"saved-model"}, Paused: tc.providerPaused,
				}
			}
			for _, providerID := range []string{"verified-provider", "unverified-provider"} {
				p := reg.Register(providerID, nil, &protocol.RegisterMessage{ModelAutopilot: state, PrivateOnly: tc.private})
				p.Mu().Lock()
				p.AccountID = "private-owner"
				p.Mu().Unlock()
				if providerID == "verified-provider" && !reg.BindVerifiedMachineIdentity(p, "private-owner", id) {
					t.Fatal("verified binding rejected")
				}
			}
			machine := patchAutopilotMachine(t, server, id, store.MachineAutopilotLive)
			if machine.MachineID != id || machine.DesiredMode != store.MachineAutopilotLive || machine.Revision != 1 || len(machine.Sessions) != 1 {
				t.Fatalf("persisted intent or verified session missing: %+v", machine)
			}
			session := machine.Sessions[0]
			if session.ProviderID != "verified-provider" || session.EffectiveMode != tc.effectiveMode || session.ControlActive || session.CapacityFresh || session.Consented == tc.noConsent || session.Paused != (tc.globalPaused || tc.providerPaused) || session.PrivateOnly != tc.private {
				t.Fatalf("desired mode bypassed runtime gates: %+v", session)
			}
			body := autopilotMachineRequest(t, server, http.MethodGet, autopilotMachinesPath, autopilotMachinesAdminKey, "", http.StatusOK)
			for _, secret := range []string{"private-owner", "private-se-", "private-serial-", "private-app-attest-", "private-consent-revision", "private-consent-session", "unverified-provider", autopilotMachinesAdminKey} {
				if strings.Contains(string(body), secret) {
					t.Fatalf("machine response leaks %q", secret)
				}
			}
			var raw struct {
				Machines []map[string]json.RawMessage `json:"machines"`
			}
			if err := json.Unmarshal(body, &raw); err != nil || len(raw.Machines) != 1 || len(raw.Machines[0]) != 4 {
				t.Fatalf("unexpected machine fields: %s (%v)", body, err)
			}
			var sessions []map[string]json.RawMessage
			if err := json.Unmarshal(raw.Machines[0]["sessions"], &sessions); err != nil || len(sessions) != 1 || len(sessions[0]) != 7 {
				t.Fatalf("unexpected session fields: %s (%v)", body, err)
			}
			for _, field := range []string{"provider_id", "effective_mode", "control_active", "consented", "paused", "private_only", "capacity_fresh"} {
				if _, present := sessions[0][field]; !present {
					t.Fatalf("session field %s omitted: %s", field, body)
				}
			}
			page := listAutopilotMachines(t, server, "")
			if len(page.Machines) != 1 || page.Machines[0].DesiredMode != machine.DesiredMode || page.Machines[0].Revision != machine.Revision || len(page.Machines[0].Sessions) != 1 || page.Machines[0].Sessions[0] != session {
				t.Fatalf("readback disagrees with update: %+v", page)
			}
			reg.Disconnect("verified-provider")
			page = listAutopilotMachines(t, server, "")
			if len(page.Machines) != 1 || page.Machines[0].DesiredMode != store.MachineAutopilotLive || page.Machines[0].Revision != 1 || page.Machines[0].Sessions == nil || len(page.Machines[0].Sessions) != 0 {
				t.Fatalf("disconnect lost intent or retained a session: %+v", page)
			}
		})
	}
}

func TestAutopilotMachinesCachedStoreAndRegistryRecreationPreserveIntent(t *testing.T) {
	st := memory.NewMemory(store.Config{})
	_, _, first := newAutopilotMachineHTTP(t, store.NewCached(st, store.CacheConfig{}))
	id := observeAutopilotMachine(t, st, "offline-machine")
	for range 2 {
		machine := patchAutopilotMachine(t, first, id, store.MachineAutopilotLive)
		if machine.DesiredMode != store.MachineAutopilotLive || machine.Revision != 1 || len(machine.Sessions) != 0 {
			t.Fatalf("offline idempotent intent through cached store: %+v", machine)
		}
	}
	if again := observeAutopilotMachine(t, st, "offline-machine"); again != id {
		t.Fatal("reobservation changed machine identity")
	}
	first.Close()
	reg, _, second := newAutopilotMachineHTTP(t, store.NewCached(st, store.CacheConfig{}))
	page := listAutopilotMachines(t, second, "")
	if len(page.Machines) != 1 || page.Machines[0].MachineID != id || page.Machines[0].DesiredMode != store.MachineAutopilotLive || page.Machines[0].Revision != 1 || page.Machines[0].Sessions == nil || len(page.Machines[0].Sessions) != 0 || reg.AutopilotSnapshot().Enabled {
		t.Fatalf("new registry lost durable intent or implied control: %+v", page)
	}
	for _, mode := range []store.MachineAutopilotMode{store.MachineAutopilotShadow, store.MachineAutopilotLive} {
		machine := patchAutopilotMachine(t, second, id, mode)
		wantRevision := int64(2)
		if mode == store.MachineAutopilotLive {
			wantRevision = 3
		}
		if machine.DesiredMode != mode || machine.Revision != wantRevision || len(machine.Sessions) != 0 {
			t.Fatalf("mode change after registry recreation: %+v", machine)
		}
	}
}

func TestAutopilotMachinesMergedIDDoesNotPromoteSurvivor(t *testing.T) {
	st := memory.NewMemory(store.Config{})
	_, _, server := newAutopilotMachineHTTP(t, st)
	now := time.Now()
	survivor, err := st.ObserveMachine(context.Background(), store.MachineObservation{SessionID: "survivor", AccountID: "private-owner", SEKey: "survivor-key", VerifiedSerial: "shared-verified-serial", At: now})
	if err != nil {
		t.Fatal(err)
	}
	loserObservation := store.MachineObservation{SessionID: "loser", AccountID: "private-owner", SEKey: "loser-key", At: now}
	loser, err := st.ObserveMachine(context.Background(), loserObservation)
	if err != nil || loser.ID == survivor.ID {
		t.Fatalf("distinct identity fixture: %+v (%v)", loser, err)
	}
	patchAutopilotMachine(t, server, loser.ID, store.MachineAutopilotLive)
	loserObservation.VerifiedSerial = "shared-verified-serial"
	merged, err := st.ObserveMachine(context.Background(), loserObservation)
	if err != nil || merged.ID != survivor.ID {
		t.Fatalf("merge fixture did not converge: %+v (%v)", merged, err)
	}
	for _, mode := range []string{"live", "shadow"} {
		autopilotMachineRequest(t, server, http.MethodPatch, autopilotMachinesPath+"/"+loser.ID, autopilotMachinesAdminKey, `{"desired_mode":"`+mode+`"}`, http.StatusNotFound)
	}
	page := listAutopilotMachines(t, server, "")
	if len(page.Machines) != 1 || page.Machines[0].MachineID != survivor.ID || page.Machines[0].DesiredMode != store.MachineAutopilotShadow || page.Machines[0].Revision != 0 || len(page.Machines[0].Sessions) != 0 {
		t.Fatalf("merged ID redirected or promoted survivor: %+v", page)
	}
}

type storeWithoutMachineAutopilot struct{ store.Store }

type unavailableMachineAutopilotStore struct{ *memory.MemoryStore }

func (unavailableMachineAutopilotStore) ListMachineAutopilotSettings(context.Context, string, int) ([]store.MachineAutopilotSetting, error) {
	return nil, errors.New("private-backend-error-with-credentials")
}

func (unavailableMachineAutopilotStore) SetMachineAutopilotDesiredMode(context.Context, string, store.MachineAutopilotMode) (store.MachineAutopilotSetting, error) {
	return store.MachineAutopilotSetting{}, errors.New("private-backend-error-with-credentials")
}

func TestAutopilotMachinesUnavailableStoreSanitizesErrors(t *testing.T) {
	for _, missing := range []bool{true, false} {
		name := "backend error"
		if missing {
			name = "missing capability"
		}
		t.Run(name, func(t *testing.T) {
			st := memory.NewMemory(store.Config{})
			var backend store.Store = unavailableMachineAutopilotStore{st}
			if missing {
				backend = storeWithoutMachineAutopilot{st}
			}
			_, _, server := newAutopilotMachineHTTP(t, backend)
			id := observeAutopilotMachine(t, st, "unavailable-machine")
			for _, req := range []struct{ method, path, body string }{
				{http.MethodGet, autopilotMachinesPath, ""},
				{http.MethodPatch, autopilotMachinesPath + "/" + id, `{"desired_mode":"live"}`},
			} {
				body := autopilotMachineRequest(t, server, req.method, req.path, autopilotMachinesAdminKey, req.body, http.StatusServiceUnavailable)
				if strings.Contains(string(body), "private-backend") || !strings.Contains(string(body), `"type":"server_error"`) {
					t.Fatalf("backend error was not sanitized: %s", body)
				}
			}
			rows, err := st.ListMachineAutopilotSettings(context.Background(), "", 1)
			if err != nil || len(rows) != 1 || rows[0].DesiredMode != store.MachineAutopilotShadow || rows[0].Revision != 0 {
				t.Fatalf("unavailable backend changed intent: %+v (%v)", rows, err)
			}
		})
	}
}
