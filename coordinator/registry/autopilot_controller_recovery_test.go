package registry

import (
	"errors"
	"math"
	"reflect"
	"slices"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func TestAutopilotControllerPendingFutureLosesCreditWhenRecipientStopsQualifying(t *testing.T) {
	for _, mutation := range []string{"stale", "private", "runtime", "catalog"} {
		t.Run(mutation, func(t *testing.T) {
			reg, c, now := newAutopilotControllerTest(t, false)
			p := autopilotControllerProvider(t, reg, "provider", now)
			if _, ok := reg.reserveAutopilotAction(c, autopilotControllerPlan(t, reg, c, now), now); !ok {
				t.Fatal("reserve failed")
			}
			if got := autopilotCoverage(reg.autopilotFleetSnapshot(c, now)).Future[autopilotTestTarget]; got <= 0 {
				t.Fatalf("valid pending command has no future credit: %g", got)
			}
			if mutation == "catalog" {
				reg.SetModelCatalog([]CatalogEntry{{ID: autopilotTestTarget, SizeGB: 8, MinRAMGB: 16, RequiredProviderCapabilities: []string{"missing-required-capability"}}})
			} else {
				p.mu.Lock()
				switch mutation {
				case "stale":
					p.capacitySamplesAt = now.Add(-c.config.MaxSnapshotAge - time.Second)
				case "private":
					p.PrivateOnly = true
				case "runtime":
					p.RuntimeVerified = false
				}
				p.mu.Unlock()
			}
			f := reg.autopilotFleetSnapshot(c, now)
			if got := autopilotCoverage(f).Future[autopilotTestTarget]; got != 0 {
				t.Fatalf("invalid recipient still promises %g rps", got)
			}
			p.mu.Lock()
			pending := p.autopilotPending != nil
			p.mu.Unlock()
			if !pending {
				t.Fatal("loss of future credit must not erase unresolved command ownership")
			}
		})
	}
}

func TestAutopilotControllerRecoveryRetriesExactGenerationWithBound(t *testing.T) {
	reg, c, now := newAutopilotControllerTest(t, false)
	p := autopilotControllerProvider(t, reg, "provider", now)
	var sent []protocol.ModelAutopilotMessage
	reg.autopilotSender = func(_ string, command protocol.ModelAutopilotMessage) error {
		sent = append(sent, command)
		return errors.New("delivery is unknown")
	}
	c.tick(now)
	for _, tc := range []struct {
		after time.Duration
		want  int
	}{
		{29 * time.Second, 1}, {30 * time.Second, 2}, {31 * time.Second, 2}, {60 * time.Second, 3}, {120 * time.Second, 3},
	} {
		reg.retryAutopilotCommands(now.Add(tc.after))
		if len(sent) != tc.want {
			t.Fatalf("after %s sent=%d want=%d", tc.after, len(sent), tc.want)
		}
	}
	for _, command := range sent {
		if !reflect.DeepEqual(command, sent[0]) {
			t.Fatalf("retry changed generation or expiry: first=%+v retry=%+v", sent[0], command)
		}
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.autopilotPending == nil || p.autopilotPending.Attempts != 3 || !p.autopilotPending.Uncertain {
		t.Fatalf("retry lost bounded uncertain ownership: %+v", p.autopilotPending)
	}
}

func TestAutopilotControllerOnlyInitialProvenQueueFullReleasesReservation(t *testing.T) {
	for _, retry := range []bool{false, true} {
		t.Run(map[bool]string{false: "initial queue full", true: "retry queue full"}[retry], func(t *testing.T) {
			reg, c, now := newAutopilotControllerTest(t, false)
			p := autopilotControllerProvider(t, reg, "provider", now)
			calls := 0
			reg.autopilotSender = func(string, protocol.ModelAutopilotMessage) error {
				calls++
				if retry && calls == 1 {
					return errors.New("first delivery uncertain")
				}
				return ErrProviderWriterQueueFull
			}
			c.tick(now)
			if retry {
				reg.retryAutopilotCommands(now.Add(30 * time.Second))
			}
			p.mu.Lock()
			pending := p.autopilotPending
			backoff := p.autopilotBackoffUntil
			p.mu.Unlock()
			if retry && (pending == nil || !pending.Uncertain) {
				t.Fatal("retry queue failure erased uncertain first delivery")
			}
			if !retry && (pending != nil || !backoff.After(now)) {
				t.Fatalf("initial unqueued command should release with backoff: pending=%+v backoff=%v", pending, backoff)
			}
		})
	}
}

func TestAutopilotControllerTerminalStatusCannotFlipBeforeHeartbeat(t *testing.T) {
	for _, first := range []string{protocol.LoadModelStatusSucceeded, protocol.LoadModelStatusFailed} {
		t.Run(first, func(t *testing.T) {
			reg, c, now := newAutopilotControllerTest(t, false)
			p := autopilotControllerProvider(t, reg, "provider", now)
			command, ok := reg.reserveAutopilotAction(c, autopilotControllerPlan(t, reg, c, now), now)
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
			p.mu.Lock()
			pending := p.autopilotPending
			p.mu.Unlock()
			if pending == nil || pending.Status != first {
				t.Fatalf("terminal ownership changed before authoritative heartbeat: %+v", pending)
			}
		})
	}
}

func TestAutopilotControllerConfigRejectsUnsafeTimingAndNumericSettings(t *testing.T) {
	for _, tc := range []struct {
		name   string
		change func(*AutopilotConfig)
	}{
		{"zero snapshot freshness", func(c *AutopilotConfig) { c.MaxSnapshotAge = 0 }},
		{"long stale snapshot", func(c *AutopilotConfig) { c.MaxSnapshotAge = time.Hour }},
		{"expired acceptance", func(c *AutopilotConfig) { c.CommandAcceptTimeout = 0 }},
		{"watchdog before acceptance", func(c *AutopilotConfig) { c.CommandWatchdog = time.Second }},
		{"unbounded watchdog", func(c *AutopilotConfig) { c.CommandWatchdog = time.Hour }},
		{"zero backoff", func(c *AutopilotConfig) { c.FailureBackoff = 0 }},
		{"zero load prior", func(c *AutopilotConfig) { c.LoadTimePrior = 0 }},
		{"nan utilization", func(c *AutopilotConfig) { c.TargetUtilization = math.NaN() }},
		{"infinite benefit", func(c *AutopilotConfig) { c.MinBenefitSeconds = math.Inf(1) }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			c := DefaultAutopilotConfig()
			c.Enabled = true
			tc.change(&c)
			if c.Check() == nil {
				t.Fatal("invalid active control policy accepted")
			}
		})
	}
}

func TestAutopilotControllerNormalUnloadIsNotReportedAsUncertain(t *testing.T) {
	reg, c, now := newAutopilotControllerTest(t, false)
	p := autopilotControllerProvider(t, reg, "provider", now, autopilotTestDonor)
	p.mu.Lock()
	p.autopilotPending = &autopilotPendingCommand{Command: protocol.ModelAutopilotMessage{CommandID: "unload", ExpectedResidentModels: []string{autopilotTestDonor}, UnloadModelIDs: []string{autopilotTestDonor}}, SentAt: now, CapacitySeq: 10, Status: "reserved"}
	p.mu.Unlock()
	summary := autopilotSummary(reg.autopilotFleetSnapshot(c, now), c.config, now)
	if summary.Pending != 1 || summary.Uncertain != 0 {
		t.Fatalf("normal unload falsely reported as uncertain: %+v", summary)
	}
	reg.markAutopilotWatchdogs(c.config, now.Add(c.config.CommandWatchdog+time.Second))
	summary = autopilotSummary(reg.autopilotFleetSnapshot(c, now), c.config, now)
	if summary.Uncertain != 1 {
		t.Fatalf("watchdog uncertainty was not surfaced: %+v", summary)
	}
}

func TestAutopilotControllerFailedHeartbeatUsesReservedBackoff(t *testing.T) {
	reg, c, now := newAutopilotControllerTest(t, false)
	c.config.FailureBackoff = 7 * time.Minute
	p := autopilotControllerProvider(t, reg, "provider", now)
	command, ok := reg.reserveAutopilotAction(c, autopilotControllerPlan(t, reg, c, now), now)
	if !ok {
		t.Fatal("reserve failed")
	}
	state := autopilotControllerState()
	state.LastCommandID, state.LastCommandStatus = command.CommandID, protocol.LoadModelStatusFailed
	p.mu.Lock()
	p.capacitySeq = 11
	p.BackendCapacity = autopilotControllerCapacity(11)
	reg.reconcileAutopilotHeartbeatLocked(p, state, now.Add(time.Second))
	pending, until := p.autopilotPending, p.autopilotBackoffUntil
	p.mu.Unlock()
	if pending != nil || !until.Equal(now.Add(time.Second+7*time.Minute)) {
		t.Fatalf("configured backoff lost on reconciliation: pending=%+v until=%v", pending, until)
	}
}

func TestAutopilotControllerFutureUsesOccupancyOnlyCoResidentWork(t *testing.T) {
	reg, c, now := newAutopilotControllerTest(t, false)
	p := autopilotControllerProvider(t, reg, "pending", now, autopilotTestDonor)
	busy := autopilotControllerProvider(t, reg, "busy-donor", now, autopilotTestDonor)
	for range 100 {
		c.demand.record(AutopilotDemandSample{Model: autopilotTestTarget, ReceivedAt: now.Add(-time.Minute), PromptTokens: 32, RequestedMaxTokens: 64}, now, c.config.DemandWindow)
	}
	p.mu.Lock()
	p.autopilotPending = &autopilotPendingCommand{Command: protocol.ModelAutopilotMessage{CommandID: "pending-load", LoadModelID: autopilotTestTarget, ExpectedResidentModels: []string{autopilotTestDonor}, UnloadModelIDs: []string{}}, SentAt: now, CapacitySeq: 10, Status: "reserved"}
	p.mu.Unlock()
	busy.mu.Lock()
	busy.BackendCapacity.Slots[0].NumRunning = 8
	busy.mu.Unlock()
	f := reg.autopilotFleetSnapshot(c, now)
	coverage := autopilotCoverage(f)
	var pending autopilotNode
	for _, node := range f.Nodes {
		if node.ID == p.ID {
			pending = node
		}
	}
	if !slices.Contains(pending.FutureResidents, autopilotTestTarget) || !slices.Contains(pending.FutureResidents, autopilotTestDonor) {
		t.Fatalf("runtime lost exact future serving set: %+v", pending.FutureResidents)
	}
	naive := autopilotNodeContribution(pending, pending.FutureResidents, f.Demand)
	if coverage.Future[autopilotTestDonor] <= 0 || coverage.Future[autopilotTestTarget] >= naive[autopilotTestTarget] {
		t.Fatalf("pending target was overcredited by ignoring unfinished co-resident work: future=%+v raw-demand-only=%+v", coverage.Future, naive)
	}
}
