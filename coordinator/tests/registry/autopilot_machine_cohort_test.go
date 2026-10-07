package registry_test

import (
	"context"
	"encoding/json"
	"reflect"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/attestation"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/autopilotcontrol"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/registry/autopilot"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func readAutopilotControl(t *testing.T, w *writerFixture) protocol.ModelAutopilotControl {
	t.Helper()
	var control protocol.ModelAutopilotControl
	select {
	case frame := <-w.lanes.Receive(true):
		if err := json.Unmarshal(w.executeFrame(frame), &control); err != nil {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("missing control lease")
	}
	return control
}

func TestAutopilotLiveCohortRequiresVerifiedSelectedMachine(t *testing.T) {
	selected := autopilotFixtureMachineID(0)
	for _, mode := range []string{"selected", "empty allowlist", "global shadow", "same account other machine", "unverified", "session spoof", "owner mismatch", "empty owner"} {
		t.Run(mode, func(t *testing.T) {
			cfg := autopilot.DefaultConfig()
			cfg.ObserveOnly = mode == "global shadow"
			cfg.LiveMachineIDs = strings.ToUpper(selected)
			machine, id := selected, "connection"
			switch mode {
			case "empty allowlist":
				cfg.LiveMachineIDs = ""
			case "same account other machine":
				machine = autopilotFixtureMachineID(1)
			case "unverified", "session spoof":
				machine = ""
				if mode == "session spoof" {
					id = selected
				}
			}
			w := newWriterFixture(0, 8, nil, nil, nil, nil)
			t.Cleanup(func() { w.Close(); w.Run() })
			var commands []protocol.ModelAutopilotMessage
			r, c, now := newAutopilotControllerTestConfig(t, cfg, func(d *production.Dependencies) {
				d.Connections = autopilotDeliveryWriters{id: w}
				d.AutopilotSender = func(_ string, cmd protocol.ModelAutopilotMessage) error { commands = append(commands, cmd); return nil }
			})
			p := autopilotMachineProvider(t, r, id, machine, now)
			p.Mu().Lock()
			if machine == "" {
				// Plausible raw identity and a forged live ack are not verified
				// machine continuity, even when a connection UUID also matches.
				p.AttestationResult = &attestation.VerificationResult{SerialNumber: selected, PublicKey: selected}
				p.ModelAutopilot.Active, p.ModelAutopilot.ObserveOnly = true, false
			}
			if mode == "owner mismatch" {
				p.AccountID = "another-owner"
			} else if mode == "empty owner" {
				p.AccountID = ""
			}
			p.Mu().Unlock()
			summary := c.Tick(now)
			control := readAutopilotControl(t, w)
			live := mode == "selected"
			if !control.Enabled || control.ObserveOnly == live || control.SessionID != id || control.ExpiresAtMS <= now.UnixMilli() {
				t.Fatalf("wrong effective control: %+v", control)
			}
			if summary.ObserveOnly != cfg.ObserveOnly || summary.Proposed != 1 || summary.OptedIn != 1 {
				t.Fatalf("missing per-machine plan: %+v", summary)
			}
			if live {
				if summary.LiveCohort != 1 || summary.LiveActive != 1 || summary.Shadow != 0 || summary.LiveProposed != 1 || summary.ShadowProposed != 0 || summary.Issued != 1 || len(commands) != 1 {
					t.Fatalf("selected verified machine did not receive live operation: %+v", summary)
				}
			} else {
				if summary.LiveCohort != 0 || summary.LiveActive != 0 || summary.Shadow != 1 || summary.LiveProposed != 0 || summary.ShadowProposed != 1 || summary.Issued != 0 || len(commands) != 0 {
					t.Fatalf("nonmember lost shadow behavior or received a live operation: %+v", summary)
				}
				p.Mu().Lock()
				_, pending := r.states[id].PrepareDelivery()
				blocked := r.states[id].LegacyChangesBlocked(p.ModelAutopilot, id, time.Now) || r.states[id].RoutingBlocked(p.ModelAutopilot, id, autopilotTestTarget, p.BackendCapacity, time.Now)
				p.Mu().Unlock()
				if pending || blocked {
					t.Fatal("shadow gained operation ownership or changed ordinary serving")
				}
			}
			body, err := json.Marshal(summary)
			if err != nil || strings.Contains(string(body), selected) || strings.Contains(string(body), "autopilot-fixture-owner") {
				t.Fatal("aggregate summary exposed machine or account identity")
			}
		})
	}
}

func TestAutopilotMixedCohortIsolatesLoadReplacementAndUnload(t *testing.T) {
	for _, operation := range []string{"load", "replacement", "unload"} {
		t.Run(operation, func(t *testing.T) {
			cfg := autopilot.DefaultConfig()
			cfg.ObserveOnly, cfg.LiveMachineIDs = false, autopilotFixtureMachineID(0)
			cfg.MaxActionsPerTick, cfg.MaxConcurrentOperations = 1, 1
			writers := autopilotDeliveryWriters{}
			for _, id := range []string{"z-live", "a-shadow"} {
				w := newWriterFixture(0, 8, nil, nil, nil, nil)
				writers[id] = w
				t.Cleanup(func() { w.Close(); w.Run() })
			}
			var sentTo []string
			var commands []protocol.ModelAutopilotMessage
			r, c, now := newAutopilotControllerTestConfig(t, cfg, func(d *production.Dependencies) {
				d.Connections = writers
				d.AutopilotSender = func(id string, cmd protocol.ModelAutopilotMessage) error {
					sentTo, commands = append(sentTo, id), append(commands, cmd)
					return nil
				}
			})
			var residents []string
			if operation != "load" {
				residents = []string{autopilotTestDonor}
			}
			live := autopilotMachineProvider(t, r, "z-live", autopilotFixtureMachineID(0), now, residents...)
			shadow := autopilotMachineProvider(t, r, "a-shadow", autopilotFixtureMachineID(1), now, residents...)
			if operation == "replacement" {
				for _, p := range []*production.Provider{live, shadow} {
					p.Mu().Lock()
					p.ModelAutopilot.MaxModelSlots = 1
					p.Mu().Unlock()
				}
			} else if operation == "unload" {
				warm := testWarmPoolConfig()
				warm.MinWarmByModel = nil
				r.ConfigureWarmPool(warm)
			}
			shadow.Mu().Lock()
			before := autopilot.CloneState(shadow.ModelAutopilot)
			capacity, err := json.Marshal(shadow.BackendCapacity)
			shadow.Mu().Unlock()
			if err != nil {
				t.Fatal(err)
			}
			summary := c.Tick(now)
			if summary.LiveCohort != 1 || summary.LiveActive != 1 || summary.Shadow != 1 || summary.Proposed != 2 || summary.LiveProposed != 1 || summary.ShadowProposed != 1 || summary.Issued != 1 || !slices.Equal(sentTo, []string{live.ID}) {
				t.Fatalf("mixed modes or independent operation budgets lost: %+v sent=%v", summary, sentTo)
			}
			for _, p := range []*production.Provider{live, shadow} {
				control := readAutopilotControl(t, writers[p.ID])
				if control.ObserveOnly != (p == shadow) || !control.Enabled {
					t.Fatalf("wrong per-machine lease: %+v", control)
				}
			}
			command := commands[0]
			if operation != "unload" && command.LoadModelID != autopilotTestTarget {
				t.Fatalf("load missing: %+v", command)
			}
			if operation != "load" && !slices.Equal(command.UnloadModelIDs, residents) {
				t.Fatalf("unload missing: %+v", command)
			}
			if operation == "unload" && command.LoadModelID != "" {
				t.Fatalf("idle unload replaced with a load: %+v", command)
			}
			shadow.Mu().Lock()
			_, shadowPending := r.states[shadow.ID].PrepareDelivery()
			afterCapacity, err := json.Marshal(shadow.BackendCapacity)
			unchanged := reflect.DeepEqual(before, shadow.ModelAutopilot) && string(capacity) == string(afterCapacity) && slices.Equal(residents, shadow.WarmModels)
			shadow.Mu().Unlock()
			live.Mu().Lock()
			_, livePending := r.states[live.ID].PrepareDelivery()
			live.Mu().Unlock()
			if err != nil || shadowPending || !livePending || r.pendingLoads.Count() != 0 || !unchanged {
				t.Fatal("hypothetical operation leaked into provider state or reservation ownership")
			}
			if !r.events.Flush(r.store, testLogger()) {
				t.Fatal("ledger flush failed")
			}
			ledger, _ := store.As[store.AutopilotStore](r.store)
			records, err := ledger.AutopilotRecords(context.Background(), time.Time{}, 20)
			if err != nil || len(records) != 2 {
				t.Fatalf("mixed proposal/command ledger: %+v %v", records, err)
			}
			for _, record := range records {
				if (record.ProviderID == shadow.ID && record.Phase != "proposed") || (record.ProviderID == live.ID && record.Phase != "reserved") {
					t.Fatalf("proposal confused with accepted work: %+v", record)
				}
			}
		})
	}
}

func TestAutopilotReservationRechecksVerifiedMachineCohort(t *testing.T) {
	for _, change := range []string{"nonmember identity", "another selected identity", "owner mismatch", "empty owner"} {
		t.Run(change, func(t *testing.T) {
			r, c, now := newAutopilotControllerTest(t, false)
			p := autopilotControllerProvider(t, r, "provider", now)
			action := autopilotControllerPlan(t, r, c, now)
			if change == "nonmember identity" || change == "another selected identity" {
				index := 100
				if change == "another selected identity" {
					index = 1
				}
				if !r.BindVerifiedMachineIdentity(p, p.AccountID, autopilotFixtureMachineID(index)) {
					t.Fatal("identity rebind rejected")
				}
			} else {
				p.Mu().Lock()
				p.AccountID = "changed-owner"
				if change == "empty owner" {
					p.AccountID = ""
				}
				p.Mu().Unlock()
			}
			if _, ok := c.Reserve(action, now); ok {
				t.Fatal("detached plan bypassed the under-lock identity/control recheck")
			}
			if _, pending := r.states[p.ID].PrepareDelivery(); pending {
				t.Fatal("rejected stale selection acquired operation ownership")
			}
		})
	}
}

func TestAutopilotMixedPlansPreserveCrossCohortDonors(t *testing.T) {
	cfg := autopilot.DefaultConfig()
	cfg.ObserveOnly, cfg.LiveMachineIDs = false, autopilotFixtureMachineID(0)
	var sent int
	r, c, now := newAutopilotControllerTestConfig(t, cfg, func(d *production.Dependencies) {
		d.AutopilotSender = func(string, protocol.ModelAutopilotMessage) error { sent++; return nil }
	})
	warm := testWarmPoolConfig()
	warm.MinWarmByModel = map[string]int{autopilotTestTarget: 1, autopilotTestDonor: 1}
	r.ConfigureWarmPool(warm)
	live := autopilotMachineProvider(t, r, "z-live", autopilotFixtureMachineID(0), now, autopilotTestDonor)
	shadow := autopilotMachineProvider(t, r, "a-shadow", autopilotFixtureMachineID(1), now, autopilotTestDonor)
	for _, p := range []*production.Provider{live, shadow} {
		p.Mu().Lock()
		p.ModelAutopilot.MaxModelSlots = 1
		p.Mu().Unlock()
	}
	fleet := c.Fleet(now)
	shadowCfg := cfg
	shadowCfg.ObserveOnly = true
	if livePlan, shadowPlan := autopilotcontrol.Plan(fleet, cfg, now), autopilotcontrol.Plan(fleet, shadowCfg, now); livePlan == nil || shadowPlan == nil || livePlan.Node.ID != live.ID || shadowPlan.Node.ID != shadow.ID {
		t.Fatalf("opposite-mode donors were filtered out: live=%+v shadow=%+v", livePlan, shadowPlan)
	}
	summary := c.Tick(now)
	if summary.LiveProposed != 1 || summary.ShadowProposed != 1 || summary.Issued != 1 || sent != 1 {
		t.Fatalf("hypothetical donor debit leaked into live plan: %+v", summary)
	}
	fleet = c.Fleet(now)
	if autopilotcontrol.Plan(fleet, shadowCfg, now) != nil || autopilot.Coverage(fleet.Fleet).Warm[autopilotTestDonor] != 1 {
		t.Fatal("accepted live transition did not protect the remaining shadow donor")
	}
	// An ordinary, non-enrolled peer remains real donor evidence for shadow too.
	ordinary := makeSchedulerProvider(t, r.Registry, "ordinary", autopilotTestDonor, 100)
	r.Heartbeat(ordinary.ID, &protocol.HeartbeatMessage{Status: "idle", BackendCapacity: autopilotControllerCapacity(10, autopilotTestDonor), WarmModels: []string{autopilotTestDonor}})
	ordinary.Mu().Lock()
	r.samples[ordinary.ID].MarkAccepted(now)
	ordinary.Mu().Unlock()
	if plan := autopilotcontrol.Plan(c.Fleet(now), shadowCfg, now); plan == nil || plan.Node.ID != shadow.ID {
		t.Fatal("ordinary donor was removed from the shadow fleet")
	}
	r.Disconnect(ordinary.ID)
	if autopilotcontrol.Plan(c.Fleet(now), shadowCfg, now) != nil {
		t.Fatal("disconnected ordinary donor still protected a shadow unload")
	}
}
