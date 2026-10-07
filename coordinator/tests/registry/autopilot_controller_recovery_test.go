package registry_test

import (
	"context"
	"errors"
	"fmt"
	"reflect"
	"slices"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/registry/autopilot"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func TestAutopilotControllerPendingFutureLosesCreditWhenRecipientStopsQualifying(t *testing.T) {
	for _, mutation := range []string{"stale", "private", "runtime", "catalog"} {
		t.Run(mutation, func(t *testing.T) {
			reg, c, now := newAutopilotControllerTest(t, false)
			p := autopilotControllerProvider(t, reg, "provider", now)
			if _, ok := c.Reserve(autopilotControllerPlan(t, reg, c, now), now); !ok {
				t.Fatal("reserve failed")
			}
			if got := autopilot.Coverage(c.Fleet(now).Fleet).Future[autopilotTestTarget]; got <= 0 {
				t.Fatalf("valid pending command has no future credit: %g", got)
			}
			if mutation == "catalog" {
				reg.SetModelCatalog([]production.CatalogEntry{{ID: autopilotTestTarget, SizeGB: 8, MinRAMGB: 16, RequiredProviderCapabilities: []string{"missing-required-capability"}}})
			} else {
				p.Mu().Lock()
				switch mutation {
				case "stale":
					reg.samples[p.ID].MarkAccepted(now.Add(-reg.cfg.MaxSnapshotAge - time.Second))
				case "private":
					p.PrivateOnly = true
				case "runtime":
					p.RuntimeVerified = false
				}
				p.Mu().Unlock()
			}
			f := c.Fleet(now)
			if got := autopilot.Coverage(f.Fleet).Future[autopilotTestTarget]; got != 0 {
				t.Fatalf("invalid recipient still promises %g rps", got)
			}
			p.Mu().Lock()
			_, pending := reg.states[p.ID].PrepareDelivery()
			p.Mu().Unlock()
			if !pending {
				t.Fatal("loss of future credit must not erase unresolved command ownership")
			}
		})
	}
}

func TestAutopilotControllerRecoveryRetriesExactGenerationWithBound(t *testing.T) {
	var sent []protocol.ModelAutopilotMessage
	reg, c, now := newAutopilotControllerTest(t, false, func(deps *production.Dependencies) {
		deps.AutopilotSender = func(_ string, command protocol.ModelAutopilotMessage) error {
			sent = append(sent, command)
			return errors.New("delivery is unknown")
		}
	})
	p := autopilotControllerProvider(t, reg, "provider", now)
	c.Tick(now)
	for _, tc := range []struct {
		after time.Duration
		want  int
	}{
		{29 * time.Second, 1}, {30 * time.Second, 2}, {31 * time.Second, 2}, {60 * time.Second, 3}, {120 * time.Second, 3},
	} {
		c.Retry(now.Add(tc.after))
		if len(sent) != tc.want {
			t.Fatalf("after %s sent=%d want=%d", tc.after, len(sent), tc.want)
		}
	}
	for _, command := range sent {
		if !reflect.DeepEqual(command, sent[0]) {
			t.Fatalf("retry changed generation or expiry: first=%+v retry=%+v", sent[0], command)
		}
	}
	p.Mu().Lock()
	defer p.Mu().Unlock()
	pending, ok := reg.states[p.ID].PrepareDelivery()
	if !ok || pending.Attempts != 3 || !pending.Uncertain {
		t.Fatalf("retry lost bounded uncertain ownership: %+v", pending)
	}
}

func TestAutopilotControllerOnlyInitialProvenQueueFullReleasesReservation(t *testing.T) {
	for _, retry := range []bool{false, true} {
		t.Run(map[bool]string{false: "initial queue full", true: "retry queue full"}[retry], func(t *testing.T) {
			calls := 0
			reg, c, now := newAutopilotControllerTest(t, false, func(deps *production.Dependencies) {
				deps.AutopilotSender = func(string, protocol.ModelAutopilotMessage) error {
					calls++
					if retry && calls == 1 {
						return errors.New("first delivery uncertain")
					}
					return production.ErrProviderWriterQueueFull
				}
			})
			p := autopilotControllerProvider(t, reg, "provider", now)
			c.Tick(now)
			if retry {
				c.Retry(now.Add(30 * time.Second))
			}
			p.Mu().Lock()
			pending, ok := reg.states[p.ID].PrepareDelivery()
			backoff := !reg.states[p.ID].Placement(p.ModelAutopilot, now, reg.cfg.CommandWatchdog).Available
			p.Mu().Unlock()
			if retry && (!ok || !pending.Uncertain) {
				t.Fatal("retry queue failure erased uncertain first delivery")
			}
			if !retry && (ok || !backoff) {
				t.Fatalf("initial unqueued command should release with backoff: pending=%+v backoff=%v", pending, backoff)
			}
			if !reg.events.Flush(reg.store, testLogger()) {
				t.Fatal("ledger flush failed")
			}
			ledger, _ := store.As[store.AutopilotStore](reg.store)
			records, err := ledger.AutopilotRecords(context.Background(), now.Add(-time.Minute), 100)
			if err != nil {
				t.Fatal(err)
			}
			failed := 0
			for _, record := range records {
				if record.Phase == "failed" {
					failed++
					if !slices.Equal(record.Before, record.After) {
						t.Fatal("proven-unsent command changed ledger residency")
					}
				}
			}
			if (!retry && failed != 1) || (retry && failed != 0) {
				t.Fatalf("failed terminal count=%d retry=%v", failed, retry)
			}
		})
	}
}

func TestAutopilotControllerTerminalStatusCannotFlipBeforeHeartbeat(t *testing.T) {
	for _, first := range []string{protocol.LoadModelStatusSucceeded, protocol.LoadModelStatusFailed} {
		t.Run(first, func(t *testing.T) {
			reg, c, now := newAutopilotControllerTest(t, false)
			p := autopilotControllerProvider(t, reg, "provider", now)
			command, ok := c.Reserve(autopilotControllerPlan(t, reg, c, now), now)
			if !ok {
				t.Fatal("reserve failed")
			}
			status := func(value string) bool {
				return reg.HandleAutopilotStatus(p.ID, p, &protocol.ModelAutopilotStatusMessage{CommandID: command.CommandID, Status: value})
			}
			if !status(first) || !status(first) {
				t.Fatal("same terminal and identical duplicate must be accepted")
			}
			other := protocol.LoadModelStatusSucceeded
			if first == other {
				other = protocol.LoadModelStatusFailed
			}
			if status(other) || status(protocol.LoadModelStatusStarted) {
				t.Fatal("terminal command was reopened by a contradictory status")
			}
			p.Mu().Lock()
			pending, ok := reg.states[p.ID].PrepareDelivery()
			p.Mu().Unlock()
			if !ok || pending.Status != first {
				t.Fatalf("terminal ownership changed before authoritative heartbeat: %+v", pending)
			}
		})
	}
}

func TestAutopilotControllerNormalUnloadIsNotReportedAsUncertain(t *testing.T) {
	reg, c, now := newAutopilotControllerTest(t, false)
	p := autopilotControllerProvider(t, reg, "provider", now, autopilotTestDonor)
	p.Mu().Lock()
	reg.states[p.ID].Reserve(protocol.ModelAutopilotMessage{CommandID: "unload", ExpectedResidentModels: []string{autopilotTestDonor}, UnloadModelIDs: []string{autopilotTestDonor}}, 10, now, 0)
	p.Mu().Unlock()
	summary := autopilot.Summarize(c.Fleet(now).Fleet, reg.cfg, now)
	if summary.Pending != 1 || summary.Uncertain != 0 {
		t.Fatalf("normal unload falsely reported as uncertain: %+v", summary)
	}
	c.Watchdogs(now.Add(reg.cfg.CommandWatchdog + time.Second))
	summary = autopilot.Summarize(c.Fleet(now).Fleet, reg.cfg, now)
	if summary.Uncertain != 1 {
		t.Fatalf("watchdog uncertainty was not surfaced: %+v", summary)
	}
}

func TestAutopilotControllerFailedHeartbeatUsesReservedBackoff(t *testing.T) {
	cfg := autopilot.DefaultConfig()
	cfg.Enabled, cfg.ObserveOnly = true, false
	cfg.FailureBackoff = 7 * time.Minute
	clock := time.Now()
	reg, c, now := newAutopilotControllerTestConfig(t, cfg, func(deps *production.Dependencies) {
		deps.HeartbeatNow = func() time.Time { return clock }
	})
	p := autopilotControllerProvider(t, reg, "provider", now)
	command, ok := c.Reserve(autopilotControllerPlan(t, reg, c, now), now)
	if !ok {
		t.Fatal("reserve failed")
	}
	state := autopilotControllerState()
	state.LastCommandID, state.LastCommandStatus = command.CommandID, protocol.LoadModelStatusFailed
	clock = now.Add(time.Second)
	reg.Heartbeat(p.ID, &protocol.HeartbeatMessage{Status: "idle", BackendCapacity: autopilotControllerCapacity(11), ModelAutopilot: state})
	p.Mu().Lock()
	_, pending := reg.states[p.ID].PrepareDelivery()
	until := now.Add(time.Second + 7*time.Minute)
	before := reg.states[p.ID].Placement(state, until.Add(-time.Nanosecond), reg.cfg.CommandWatchdog).Available
	at := reg.states[p.ID].Placement(state, until, reg.cfg.CommandWatchdog).Available
	p.Mu().Unlock()
	if pending || before || !at {
		t.Fatalf("configured backoff lost on reconciliation: pending=%+v until=%v", pending, until)
	}
}

func TestAutopilotControllerFutureIncludesPublicInflightCoResidentWork(t *testing.T) {
	reg, c, now := newAutopilotControllerTest(t, false)
	p := autopilotControllerProvider(t, reg, "pending", now, autopilotTestDonor)
	busy := autopilotControllerProvider(t, reg, "busy-donor", now, autopilotTestDonor)
	for range 100 {
		reg.demand.Record(autopilot.DemandSample{Model: autopilotTestTarget, ReceivedAt: now.Add(-time.Minute), PromptTokens: 32, RequestedMaxTokens: 64}, now, reg.cfg.DemandWindow)
	}
	p.Mu().Lock()
	reg.states[p.ID].Reserve(protocol.ModelAutopilotMessage{CommandID: "pending-load", LoadModelID: autopilotTestTarget, ExpectedResidentModels: []string{autopilotTestDonor}, UnloadModelIDs: []string{}}, 10, now, 0)
	p.Mu().Unlock()
	busy.Mu().Lock()
	busy.BackendCapacity.Slots[0].NumRunning = 8
	busy.Mu().Unlock()
	for i := range 8 {
		request := autopilotActiveRequest(fmt.Sprint(i), autopilotTestDonor, now)
		busy.AddPending(request)
	}
	f := c.Fleet(now)
	coverage := autopilot.Coverage(f.Fleet)
	var pending autopilot.Node
	for _, node := range f.Nodes {
		if node.ID == p.ID {
			pending = node
		}
	}
	if !slices.Contains(pending.FutureResidents, autopilotTestTarget) || !slices.Contains(pending.FutureResidents, autopilotTestDonor) {
		t.Fatalf("runtime lost exact future serving set: %+v", pending.FutureResidents)
	}
	naive := autopilot.NodeContribution(pending, pending.FutureResidents, f.Demand)
	if autopilotModelRate(coverage.Future, autopilotTestDonor) <= 0 || autopilotModelRate(coverage.Future, autopilotTestTarget) >= autopilotModelRate(naive, autopilotTestTarget) {
		t.Fatalf("pending target was overcredited by ignoring unfinished co-resident work: future=%+v raw-demand-only=%+v", coverage.Future, naive)
	}
}

func autopilotModelRate(rates map[string]float64, model string) float64 {
	var total float64
	for key, rate := range rates {
		if autopilot.ModelID(key) == model {
			total += rate
		}
	}
	return total
}
