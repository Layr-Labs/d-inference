package registry_test

import (
	"encoding/json"
	"errors"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/autopilotcontrol"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/pendingload"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/registry/autopilot"
)

func TestAutopilotControllerObserveOnlyNeverReservesOrSends(t *testing.T) {
	var sent int
	reg, c, now := newAutopilotControllerTest(t, true, func(deps *production.Dependencies) {
		deps.AutopilotSender = func(string, protocol.ModelAutopilotMessage) error { sent++; return nil }
	})
	p := autopilotControllerProvider(t, reg, "provider", now)
	before := reg.AutopilotSnapshot()
	s := c.Tick(now)
	seq := c.Fleet(now).Nodes[0].Seq
	p.Mu().Lock()
	_, pending := reg.states[p.ID].PrepareDelivery()
	active := p.ModelAutopilot.ActiveCommandID
	p.Mu().Unlock()
	if s.Proposed != 1 || s.Issued != 0 || sent != 0 || pending || active != "" || seq != 10 {
		t.Fatalf("observe-only mutated control state: summary=%+v sent=%d pending=%+v active=%q seq=%d", s, sent, pending, active, seq)
	}
	if !before.At.IsZero() || reg.AutopilotSnapshot().Proposed != 1 {
		t.Fatal("observation summary was not published independently")
	}
	// The hypothetical plan must not turn a warm node into a transition fence.
	p.Mu().Lock()
	p.BackendCapacity = autopilotControllerCapacity(11, autopilotTestTarget)
	p.ModelAutopilot = autopilotControllerState(autopilotTestTarget)
	blocked := reg.states[p.ID].RoutingBlocked(p.ModelAutopilot, p.ID, autopilotTestTarget, p.BackendCapacity, time.Now)
	p.Mu().Unlock()
	if blocked {
		t.Fatal("hypothetical reservation leaked into routing")
	}
}

func TestAutopilotControllerActiveReservesAndEncodesEmptyArrays(t *testing.T) {
	var commands []protocol.ModelAutopilotMessage
	reg, c, now := newAutopilotControllerTest(t, false, func(deps *production.Dependencies) {
		deps.AutopilotSender = func(_ string, cmd protocol.ModelAutopilotMessage) error { commands = append(commands, cmd); return nil }
	})
	p := autopilotControllerProvider(t, reg, "provider", now)
	s := c.Tick(now)
	if s.Issued != 1 || len(commands) != 1 {
		t.Fatalf("active tick did not issue one operation: summary=%+v commands=%+v", s, commands)
	}
	cmd := commands[0]
	p.Mu().Lock()
	pending, ok := reg.states[p.ID].PrepareDelivery()
	blocked := reg.states[p.ID].RoutingBlocked(p.ModelAutopilot, p.ID, autopilotTestTarget, p.BackendCapacity, time.Now)
	p.Mu().Unlock()
	if !ok || pending.Command.CommandID != cmd.CommandID || !blocked || cmd.LoadModelID != autopilotTestTarget {
		t.Fatalf("command was not reserved before send: command=%+v pending=%+v blocked=%v", cmd, pending, blocked)
	}
	body, err := json.Marshal(cmd)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(body), `"expected_resident_models":[]`) || !strings.Contains(string(body), `"unload_model_ids":[]`) {
		t.Fatalf("Swift requires concrete arrays, including empty: %s", body)
	}
	if !slices.Equal(cmd.ExpectedResidentModels, []string{}) || cmd.ExpiresAtMS <= now.UnixMilli() {
		t.Fatalf("invalid command preconditions: %+v", cmd)
	}
}

func TestAutopilotControllerReservationRevalidatesSessionSequenceAndState(t *testing.T) {
	for _, mutation := range []string{"session", "sequence", "residency", "optout", "pending_work", "stale_capacity", "pin"} {
		t.Run(mutation, func(t *testing.T) {
			reg, c, now := newAutopilotControllerTest(t, false)
			p := autopilotControllerProvider(t, reg, "provider", now, autopilotTestDonor)
			p.Mu().Lock()
			p.ModelAutopilot.MaxModelSlots = 1 // replacement requires explicit victim
			p.Mu().Unlock()
			a := autopilotControllerPlan(t, reg, c, now)
			if mutation == "session" {
				reg.Disconnect(p.ID)
				autopilotControllerProvider(t, reg, p.ID, now, autopilotTestDonor)
			} else if mutation == "sequence" {
				p.Mu().Lock()
				sequence := p.BackendCapacity.CapacitySeq + 1
				state := autopilot.CloneState(p.ModelAutopilot)
				metrics := p.SystemMetrics
				warmModels := append([]string{}, p.WarmModels...)
				p.Mu().Unlock()
				reg.Heartbeat(p.ID, &protocol.HeartbeatMessage{Status: "idle", BackendCapacity: autopilotControllerCapacity(sequence, autopilotTestDonor), ModelAutopilot: state, SystemMetrics: metrics, WarmModels: warmModels})
			} else {
				p.Mu().Lock()
				switch mutation {
				case "residency":
					p.ModelAutopilot.ResidentModels = nil
				case "optout":
					p.ModelAutopilot.Enabled = false
				case "pending_work":
					p.BackendCapacity.Slots[0].NumRunning = 1
				case "stale_capacity":
					reg.samples[p.ID].MarkAccepted(now.Add(-reg.cfg.MaxSnapshotAge - time.Second))
				case "pin":
					p.ModelAutopilot.PinnedModels = []string{autopilotTestDonor}
				}
				p.Mu().Unlock()
			}
			if cmd, ok := c.Reserve(a, now); ok {
				t.Fatalf("stale %s plan reserved: %+v", mutation, cmd)
			}
		})
	}
}

func TestAutopilotControllerSequentialActionsCannotSpendSameDonorFloor(t *testing.T) {
	var sent int
	reg, c, now := newAutopilotControllerTest(t, false, func(deps *production.Dependencies) {
		deps.AutopilotSender = func(string, protocol.ModelAutopilotMessage) error { sent++; return nil }
	})
	warm := testWarmPoolConfig()
	warm.MinWarmByModel = map[string]int{autopilotTestTarget: 1, autopilotTestDonor: 1}
	reg.ConfigureWarmPool(warm)
	autopilotControllerProvider(t, reg, "first", now, autopilotTestDonor)
	autopilotControllerProvider(t, reg, "second", now, autopilotTestDonor)
	for range 1000 {
		reg.demand.Record(autopilot.DemandSample{Model: autopilotTestTarget, ReceivedAt: now.Add(-time.Minute), PromptTokens: 32, RequestedMaxTokens: 64}, now, reg.cfg.DemandWindow)
	}
	s := c.Tick(now)
	if s.Issued != 1 || sent != 1 {
		t.Fatalf("one donor must remain outside transitions: summary=%+v sent=%d", s, sent)
	}
	c.Tick(now.Add(time.Second))
	if sent != 1 {
		t.Fatalf("next tick reused donor capacity awaiting heartbeat: sent=%d", sent)
	}
}

func TestAutopilotControllerPendingNeedsMatchingFreshAuthoritativeHeartbeat(t *testing.T) {
	reg, c, now := newAutopilotControllerTest(t, false)
	p := autopilotControllerProvider(t, reg, "provider", now)
	a := autopilotControllerPlan(t, reg, c, now)
	cmd, ok := c.Reserve(a, now)
	if !ok {
		t.Fatal("reservation failed")
	}
	if !reg.HandleAutopilotStatus(p.ID, p, &protocol.ModelAutopilotStatusMessage{CommandID: cmd.CommandID, Status: protocol.LoadModelStatusSucceeded}) {
		t.Fatal("matching status was rejected")
	}
	p.Mu().Lock()
	_, pending := reg.states[p.ID].PrepareDelivery()
	if !pending || len(p.BackendCapacity.Slots) != 0 || len(p.WarmModels) != 0 {
		t.Fatal("status manufactured warm capacity or released pending")
	}
	p.Mu().Unlock()
	for _, tc := range []struct {
		name        string
		seq         uint64
		command     string
		active      string
		residents   []string
		capacity    []string
		wantPending bool
	}{
		{"same sequence", 10, cmd.CommandID, "", []string{autopilotTestTarget}, []string{autopilotTestTarget}, true},
		{"different command", 11, "other-command", "", []string{autopilotTestTarget}, []string{autopilotTestTarget}, true},
		{"still active", 12, cmd.CommandID, cmd.CommandID, []string{autopilotTestTarget}, []string{autopilotTestTarget}, true},
		{"resident mismatch", 13, cmd.CommandID, "", []string{autopilotTestTarget}, nil, true},
		{"matched fresh", 14, cmd.CommandID, "", []string{autopilotTestTarget}, []string{autopilotTestTarget}, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			state := autopilotControllerState(tc.residents...)
			state.LastCommandID, state.LastCommandStatus, state.ActiveCommandID = tc.command, protocol.LoadModelStatusSucceeded, tc.active
			reg.Heartbeat(p.ID, &protocol.HeartbeatMessage{Status: "idle", BackendCapacity: autopilotControllerCapacity(tc.seq, tc.capacity...), ModelAutopilot: state, WarmModels: tc.capacity})
			p.Mu().Lock()
			_, pending := reg.states[p.ID].PrepareDelivery()
			p.Mu().Unlock()
			if pending != tc.wantPending {
				t.Fatalf("pending=%v want=%v", pending, tc.wantPending)
			}
		})
	}
	if reg.HandleAutopilotStatus(p.ID, p, &protocol.ModelAutopilotStatusMessage{CommandID: cmd.CommandID, Status: protocol.LoadModelStatusFailed}) {
		t.Fatal("late completed-command status was accepted")
	}
}

func TestAutopilotControllerSendAmbiguityAndWatchdogRetainFence(t *testing.T) {
	for _, sendFailure := range []bool{false, true} {
		t.Run(map[bool]string{false: "watchdog", true: "ambiguous send"}[sendFailure], func(t *testing.T) {
			reg, c, now := newAutopilotControllerTest(t, false, func(deps *production.Dependencies) {
				deps.AutopilotSender = func(string, protocol.ModelAutopilotMessage) error {
					if sendFailure {
						return errors.New("write completion unknown")
					}
					return nil
				}
			})
			p := autopilotControllerProvider(t, reg, "provider", now)
			c.Tick(now)
			if !sendFailure {
				c.Watchdogs(now.Add(reg.cfg.CommandWatchdog + time.Second))
			}
			p.Mu().Lock()
			pending, ok := reg.states[p.ID].PrepareDelivery()
			fenced := reg.states[p.ID].Transition(p.ModelAutopilot)
			p.Mu().Unlock()
			if !ok || !pending.Uncertain || !fenced {
				t.Fatalf("uncertainty restored capacity/ownership: pending=%+v fenced=%v", pending, fenced)
			}
			coverage := autopilot.Coverage(c.Fleet(now).Fleet)
			if coverage.Future[autopilotTestTarget] != 0 {
				t.Fatalf("uncertain operation still credited projected capacity: %+v", coverage.Future)
			}
		})
	}
}

func TestAutopilotControllerReconnectAndOptOutDoNotAcceptStaleAcknowledgements(t *testing.T) {
	reg, c, now := newAutopilotControllerTest(t, false)
	p := autopilotControllerProvider(t, reg, "provider", now)
	cmd, ok := c.Reserve(autopilotControllerPlan(t, reg, c, now), now)
	if !ok {
		t.Fatal("reservation failed")
	}
	state := autopilotControllerState()
	state.Enabled, state.LastCommandID, state.LastCommandStatus = false, cmd.CommandID, protocol.LoadModelStatusFailed
	reg.Heartbeat(p.ID, &protocol.HeartbeatMessage{Status: "idle", BackendCapacity: autopilotControllerCapacity(11), ModelAutopilot: state})
	p.Mu().Lock()
	_, pending := reg.states[p.ID].PrepareDelivery()
	if pending || reg.states[p.ID].Managed(p.ModelAutopilot, p.ID, time.Now()) {
		t.Fatal("matching opt-out completion did not release management")
	}
	p.Mu().Unlock()
	reg.Disconnect(p.ID)
	newSession := autopilotControllerProvider(t, reg, p.ID, now)
	if reg.HandleAutopilotStatus(p.ID, p, &protocol.ModelAutopilotStatusMessage{CommandID: cmd.CommandID, Status: protocol.LoadModelStatusSucceeded}) {
		t.Fatal("old-session acknowledgement accepted after reconnect")
	}
	newSession.Mu().Lock()
	defer newSession.Mu().Unlock()
	_, pending = reg.states[newSession.ID].PrepareDelivery()
	if pending || len(newSession.BackendCapacity.Slots) != 0 {
		t.Fatal("old command leaked into fresh connection")
	}
}

func TestAutopilotControllerConcurrentReservationsHonorBudgetWithObservedLegacyLoads(t *testing.T) {
	cfg := autopilot.DefaultConfig()
	cfg.Enabled, cfg.ObserveOnly = true, false
	cfg.MaxConcurrentOperations = 2
	reg, c, now := newAutopilotControllerTestConfig(t, cfg)
	for _, id := range []string{"a", "b", "c", "d"} {
		autopilotControllerProvider(t, reg, id, now)
	}
	for range 1000 {
		reg.demand.Record(autopilot.DemandSample{Model: autopilotTestTarget, ReceivedAt: now.Add(-time.Minute), PromptTokens: 32, RequestedMaxTokens: 64}, now, reg.cfg.DemandWindow)
	}
	key := pendingload.Key{ProviderID: "legacy", ModelID: autopilotTestTarget}
	reg.pendingLoads.Reserve(key, now.Add(time.Minute), now)
	f := c.Fleet(now)
	var actions []autopilotcontrol.Action[*production.Provider]
	for _, node := range f.Nodes {
		one := f
		one.Nodes = append([]autopilot.Node(nil), f.Nodes...)
		for i := range one.Nodes {
			one.Nodes[i].Idle = one.Nodes[i].ID == node.ID
		}
		if a := autopilotcontrol.Plan(one, reg.cfg, now); a != nil {
			actions = append(actions, *a)
		}
	}
	if len(actions) != 4 {
		t.Fatalf("fixture needs four eligible recipients: %d", len(actions))
	}
	var accepted atomic.Int32
	var wg sync.WaitGroup
	for _, action := range actions {
		wg.Add(1)
		go func(a autopilotcontrol.Action[*production.Provider]) {
			defer wg.Done()
			if _, ok := c.Reserve(a, now); ok {
				accepted.Add(1)
			}
		}(action)
	}
	wg.Wait()
	if accepted.Load() != 1 {
		t.Fatalf("shared operation budget permits one managed + one legacy, got %d managed", accepted.Load())
	}
}
