package registry

import (
	"encoding/json"
	"errors"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

const (
	autopilotTestTarget = "controller-target"
	autopilotTestDonor  = "controller-donor"
)

func newAutopilotControllerTest(t *testing.T, observe bool) (*Registry, *modelAutopilotController, time.Time) {
	t.Helper()
	reg := New(testLogger())
	reg.SetModelCatalog([]CatalogEntry{{ID: autopilotTestTarget, SizeGB: 8, MinRAMGB: 16}, {ID: autopilotTestDonor, SizeGB: 8, MinRAMGB: 16}})
	warmCfg := testWarmPoolConfig()
	warmCfg.MinWarmByModel = map[string]int{autopilotTestTarget: 1}
	reg.ConfigureWarmPool(warmCfg)
	cfg := DefaultAutopilotConfig()
	cfg.Enabled, cfg.ObserveOnly = true, observe
	if err := reg.ConfigureAutopilot(cfg); err != nil {
		t.Fatal(err)
	}
	return reg, reg.autopilot, time.Now()
}

func autopilotControllerProvider(t *testing.T, reg *Registry, id string, now time.Time, residents ...string) *Provider {
	t.Helper()
	p := makeSchedulerProvider(t, reg, id, autopilotTestTarget, 100)
	p.mu.Lock()
	p.Hardware.MemoryGB = 64
	p.PrefillTPS = 2000
	p.Models = []protocol.ModelInfo{{ID: autopilotTestTarget, SizeBytes: 8_000_000_000, ModelType: "chat"}, {ID: autopilotTestDonor, SizeBytes: 8_000_000_000, ModelType: "chat"}}
	p.syncModelIndexLocked()
	p.capacitySeq = 10
	p.capacitySamplesAt = now
	p.BackendCapacity = autopilotControllerCapacity(10, residents...)
	p.ModelAutopilot = autopilotControllerState(residents...)
	p.WarmModels = append([]string{}, residents...)
	p.mu.Unlock()
	return p
}

func autopilotControllerState(residents ...string) *protocol.ModelAutopilotState {
	free := 48.0
	s := &protocol.ModelAutopilotState{Protocol: 1, Enabled: true, CachedOnly: true, MaxModelSlots: 3, MinDwellSeconds: 60, FreeForLoadNoEvictGB: &free, ResidentModels: []protocol.ModelAutopilotResident{}, PinnedModels: []string{}}
	for _, m := range residents {
		resident := 8.0
		s.ResidentModels = append(s.ResidentModels, protocol.ModelAutopilotResident{ModelID: m, ResidentSeconds: 7200, IdleSeconds: 7200, WeightsGB: 9, ResidentGB: &resident})
	}
	return s
}

func autopilotControllerCapacity(seq uint64, residents ...string) *protocol.BackendCapacity {
	bc := &protocol.BackendCapacity{TotalMemoryGB: 64, CapacitySeq: seq, Slots: []protocol.BackendSlotCapacity{}}
	for _, m := range residents {
		bc.Slots = append(bc.Slots, protocol.BackendSlotCapacity{Model: m, State: "idle", ActiveTokenBudgetMax: 100000, KVBytesPerToken: 65536, MaxConcurrency: 8})
	}
	return bc
}

func autopilotControllerPlan(t *testing.T, reg *Registry, c *modelAutopilotController, now time.Time) autopilotAction {
	t.Helper()
	f := reg.autopilotFleetSnapshot(c, now)
	a := planAutopilotAction(f, c.config, now)
	if a == nil {
		t.Fatalf("fixture should plan a target load: fleet=%+v summary=%+v", f, autopilotSummary(f, c.config, now))
	}
	return *a
}

func TestAutopilotControllerObserveOnlyNeverReservesOrSends(t *testing.T) {
	reg, c, now := newAutopilotControllerTest(t, true)
	p := autopilotControllerProvider(t, reg, "provider", now)
	var sent int
	reg.autopilotSender = func(string, protocol.ModelAutopilotMessage) error { sent++; return nil }
	before := reg.AutopilotSnapshot()
	s := c.tick(now)
	p.mu.Lock()
	pending := p.autopilotPending
	active := p.ModelAutopilot.ActiveCommandID
	seq := p.capacitySeq
	p.mu.Unlock()
	if s.Proposed != 1 || s.Issued != 0 || sent != 0 || pending != nil || active != "" || seq != 10 {
		t.Fatalf("observe-only mutated control state: summary=%+v sent=%d pending=%+v active=%q seq=%d", s, sent, pending, active, seq)
	}
	if !before.At.IsZero() || reg.AutopilotSnapshot().Proposed != 1 {
		t.Fatal("observation summary was not published independently")
	}
	// Consent's warm-only fence is real provider policy; the hypothetical plan
	// itself must not turn a warm node into a transition fence.
	p.mu.Lock()
	p.BackendCapacity = autopilotControllerCapacity(11, autopilotTestTarget)
	p.ModelAutopilot = autopilotControllerState(autopilotTestTarget)
	blocked := providerAutopilotRoutingBlockedLocked(p, autopilotTestTarget)
	p.mu.Unlock()
	if blocked {
		t.Fatal("hypothetical reservation leaked into routing")
	}
}

func TestAutopilotControllerActiveReservesAndEncodesEmptyArrays(t *testing.T) {
	reg, c, now := newAutopilotControllerTest(t, false)
	p := autopilotControllerProvider(t, reg, "provider", now)
	var commands []protocol.ModelAutopilotMessage
	reg.autopilotSender = func(_ string, cmd protocol.ModelAutopilotMessage) error { commands = append(commands, cmd); return nil }
	s := c.tick(now)
	if s.Issued != 1 || len(commands) != 1 {
		t.Fatalf("active tick did not issue one operation: summary=%+v commands=%+v", s, commands)
	}
	cmd := commands[0]
	p.mu.Lock()
	pending := p.autopilotPending
	blocked := providerAutopilotRoutingBlockedLocked(p, autopilotTestTarget)
	p.mu.Unlock()
	if pending == nil || pending.Command.CommandID != cmd.CommandID || !blocked || cmd.LoadModelID != autopilotTestTarget {
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
			p.mu.Lock()
			p.ModelAutopilot.MaxModelSlots = 1 // replacement requires explicit victim
			p.mu.Unlock()
			a := autopilotControllerPlan(t, reg, c, now)
			if mutation == "session" {
				reg.Disconnect(p.ID)
				autopilotControllerProvider(t, reg, p.ID, now, autopilotTestDonor)
			} else {
				p.mu.Lock()
				switch mutation {
				case "sequence":
					p.capacitySeq++
				case "residency":
					p.ModelAutopilot.ResidentModels = nil
				case "optout":
					p.ModelAutopilot.Enabled = false
				case "pending_work":
					p.BackendCapacity.Slots[0].NumRunning = 1
				case "stale_capacity":
					p.capacitySamplesAt = now.Add(-c.config.MaxSnapshotAge - time.Second)
				case "pin":
					p.ModelAutopilot.PinnedModels = []string{autopilotTestDonor}
				}
				p.mu.Unlock()
			}
			if cmd, ok := reg.reserveAutopilotAction(c, a, now); ok {
				t.Fatalf("stale %s plan reserved: %+v", mutation, cmd)
			}
		})
	}
}

func TestAutopilotControllerSequentialActionsCannotSpendSameDonorFloor(t *testing.T) {
	reg, c, now := newAutopilotControllerTest(t, false)
	reg.warmPool.config.MinWarmByModel[autopilotTestDonor] = 1
	autopilotControllerProvider(t, reg, "first", now, autopilotTestDonor)
	autopilotControllerProvider(t, reg, "second", now, autopilotTestDonor)
	for range 1000 {
		c.demand.record(AutopilotDemandSample{Model: autopilotTestTarget, ReceivedAt: now.Add(-time.Minute), PromptTokens: 32, RequestedMaxTokens: 64}, now, c.config.DemandWindow)
	}
	var sent int
	reg.autopilotSender = func(string, protocol.ModelAutopilotMessage) error { sent++; return nil }
	s := c.tick(now)
	if s.Issued != 1 || sent != 1 {
		t.Fatalf("one donor must remain outside transitions: summary=%+v sent=%d", s, sent)
	}
	c.tick(now.Add(time.Second))
	if sent != 1 {
		t.Fatalf("next tick reused donor capacity awaiting heartbeat: sent=%d", sent)
	}
}

func TestAutopilotControllerPendingNeedsMatchingFreshAuthoritativeHeartbeat(t *testing.T) {
	reg, c, now := newAutopilotControllerTest(t, false)
	p := autopilotControllerProvider(t, reg, "provider", now)
	a := autopilotControllerPlan(t, reg, c, now)
	cmd, ok := reg.reserveAutopilotAction(c, a, now)
	if !ok {
		t.Fatal("reservation failed")
	}
	if !reg.HandleAutopilotStatus(p.ID, p, &protocol.ModelAutopilotStatusMessage{CommandID: cmd.CommandID, Status: protocol.LoadModelStatusSucceeded}) {
		t.Fatal("matching status was rejected")
	}
	p.mu.Lock()
	if p.autopilotPending == nil || len(p.BackendCapacity.Slots) != 0 || len(p.WarmModels) != 0 {
		t.Fatal("status manufactured warm capacity or released pending")
	}
	p.mu.Unlock()
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
			p.mu.Lock()
			pending := p.autopilotPending != nil
			p.mu.Unlock()
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
			reg, c, now := newAutopilotControllerTest(t, false)
			p := autopilotControllerProvider(t, reg, "provider", now)
			reg.autopilotSender = func(string, protocol.ModelAutopilotMessage) error {
				if sendFailure {
					return errors.New("write completion unknown")
				}
				return nil
			}
			c.tick(now)
			if !sendFailure {
				reg.markAutopilotWatchdogs(c.config, now.Add(c.config.CommandWatchdog+time.Second))
			}
			p.mu.Lock()
			pending := p.autopilotPending
			fenced := providerAutopilotTransitionLocked(p)
			p.mu.Unlock()
			if pending == nil || !pending.Uncertain || !fenced {
				t.Fatalf("uncertainty restored capacity/ownership: pending=%+v fenced=%v", pending, fenced)
			}
			coverage := autopilotCoverage(reg.autopilotFleetSnapshot(c, now))
			if coverage.Future[autopilotTestTarget] != 0 {
				t.Fatalf("uncertain operation still credited projected capacity: %+v", coverage.Future)
			}
		})
	}
}

func TestAutopilotControllerReconnectAndOptOutDoNotAcceptStaleAcknowledgements(t *testing.T) {
	reg, c, now := newAutopilotControllerTest(t, false)
	p := autopilotControllerProvider(t, reg, "provider", now)
	cmd, ok := reg.reserveAutopilotAction(c, autopilotControllerPlan(t, reg, c, now), now)
	if !ok {
		t.Fatal("reservation failed")
	}
	state := autopilotControllerState()
	state.Enabled, state.LastCommandID, state.LastCommandStatus = false, cmd.CommandID, protocol.LoadModelStatusFailed
	reg.Heartbeat(p.ID, &protocol.HeartbeatMessage{Status: "idle", BackendCapacity: autopilotControllerCapacity(11), ModelAutopilot: state})
	p.mu.Lock()
	if p.autopilotPending != nil || providerAutopilotManagedLocked(p) {
		t.Fatal("matching opt-out completion did not release management")
	}
	p.mu.Unlock()
	reg.Disconnect(p.ID)
	newSession := autopilotControllerProvider(t, reg, p.ID, now)
	if reg.HandleAutopilotStatus(p.ID, p, &protocol.ModelAutopilotStatusMessage{CommandID: cmd.CommandID, Status: protocol.LoadModelStatusSucceeded}) {
		t.Fatal("old-session acknowledgement accepted after reconnect")
	}
	newSession.mu.Lock()
	defer newSession.mu.Unlock()
	if newSession.autopilotPending != nil || len(newSession.BackendCapacity.Slots) != 0 {
		t.Fatal("old command leaked into fresh connection")
	}
}

func TestAutopilotControllerConcurrentReservationsHonorBudgetWithObservedLegacyLoads(t *testing.T) {
	reg, c, now := newAutopilotControllerTest(t, false)
	c.config.MaxConcurrentOperations = 2
	for _, id := range []string{"a", "b", "c", "d"} {
		autopilotControllerProvider(t, reg, id, now)
	}
	for range 1000 {
		c.demand.record(AutopilotDemandSample{Model: autopilotTestTarget, ReceivedAt: now.Add(-time.Minute), PromptTokens: 32, RequestedMaxTokens: 64}, now, c.config.DemandWindow)
	}
	key := modelLoadKey{ProviderID: "legacy", ModelID: autopilotTestTarget}
	reg.pendingModelLoads[key], reg.pendingModelLoadStarted[key] = now.Add(time.Minute), now
	f := reg.autopilotFleetSnapshot(c, now)
	var actions []autopilotAction
	for _, node := range f.Nodes {
		one := f
		one.Nodes = append([]autopilotNode(nil), f.Nodes...)
		for i := range one.Nodes {
			one.Nodes[i].Idle = one.Nodes[i].ID == node.ID
		}
		if a := planAutopilotAction(one, c.config, now); a != nil {
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
		go func(a autopilotAction) {
			defer wg.Done()
			if _, ok := reg.reserveAutopilotAction(c, a, now); ok {
				accepted.Add(1)
			}
		}(action)
	}
	wg.Wait()
	if accepted.Load() != 1 {
		t.Fatalf("shared operation budget permits one managed + one legacy, got %d managed", accepted.Load())
	}
}
