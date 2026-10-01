package registry

import (
	"context"
	"encoding/json"
	"errors"
	"slices"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
)

type disconnectAutopilotStore struct {
	*store.MemoryStore
	calls       atomic.Int32
	unavailable atomic.Bool
}

func (s *disconnectAutopilotStore) RecordAutopilot(ctx context.Context, records []store.AutopilotRecord) error {
	s.calls.Add(1)
	if s.unavailable.Load() {
		return errors.New("ledger unavailable")
	}
	return s.MemoryStore.RecordAutopilot(ctx, records)
}

func autopilotDisconnectWriter(t *testing.T, p *Provider, full bool) *providerWriter {
	t.Helper()
	w := &providerWriter{control: make(chan *providerWriteRequest, 2), stop: make(chan struct{}), done: make(chan struct{})}
	if full {
		w.control <- &providerWriteRequest{}
		w.control <- &providerWriteRequest{}
	}
	p.mu.Lock()
	p.writer = w
	p.ModelAutopilot.MaxModelSlots = 1 // force the command to name a donor victim
	p.mu.Unlock()
	t.Cleanup(func() { w.closeNow(); close(w.done) })
	return w
}

func TestAutopilotDisconnectQueuesDurableUncertaintyWithoutLedgerIO(t *testing.T) {
	for _, status := range []string{"reserved", protocol.LoadModelStatusStarted, protocol.LoadModelStatusSucceeded} {
		t.Run(status, func(t *testing.T) {
			r, c, now := newAutopilotControllerTest(t, false)
			ledger := &disconnectAutopilotStore{MemoryStore: store.NewMemory(store.Config{})}
			r.SetStore(ledger)
			p := autopilotControllerProvider(t, r, "disconnecting", now, autopilotTestDonor)
			w := autopilotDisconnectWriter(t, p, false)
			if summary := c.tick(now); summary.Issued != 1 || len(w.control) != 2 {
				t.Fatalf("real lease and residency command were not reserved/enqueued: %+v", summary)
			}
			var control protocol.ModelAutopilotControl
			if err := json.Unmarshal((<-w.control).data, &control); err != nil || !control.Enabled || control.ObserveOnly {
				t.Fatalf("invalid live control bookkeeping: %+v error=%v", control, err)
			}
			var command protocol.ModelAutopilotMessage
			if err := json.Unmarshal((<-w.control).data, &command); err != nil {
				t.Fatal(err)
			}
			if status != "reserved" && !r.HandleAutopilotStatus(p.ID, p, &protocol.ModelAutopilotStatusMessage{CommandID: command.CommandID, Status: status}) {
				t.Fatal("matching command acknowledgement rejected")
			}
			if !r.flushAutopilotEvents() {
				t.Fatal("pre-disconnect ledger flush failed")
			}
			calls := ledger.calls.Load()
			ledger.unavailable.Store(true)
			r.Disconnect(p.ID)
			if ledger.calls.Load() != calls {
				t.Fatal("disconnect attempted synchronous ledger IO")
			}
			if r.GetProvider(p.ID) != nil || !w.dead.Load() || len(r.autopilotFleetSnapshot(c, now).Nodes) != 0 {
				t.Fatal("disconnect left the old session, writer or future capacity registered")
			}
			p.mu.Lock()
			pending := p.autopilotPending
			if pending == nil || !pending.Uncertain || pending.Command.CommandID != command.CommandID || pending.Status != status {
				p.mu.Unlock()
				t.Fatal("disconnect discarded or falsified unresolved operation metadata")
			}
			if len(p.BackendCapacity.Slots) != 1 || p.BackendCapacity.Slots[0].Model != autopilotTestDonor {
				p.mu.Unlock()
				t.Fatal("disconnect manufactured final residency")
			}
			pending.Command.ExpectedResidentModels[0] = "discarded-prior-array"
			pending.Command.UnloadModelIDs[0] = "discarded-unload-array"
			p.mu.Unlock()
			if r.flushAutopilotEvents() {
				t.Fatal("unavailable ledger accepted uncertainty")
			}
			ledger.unavailable.Store(false)
			if !r.flushAutopilotEvents() {
				t.Fatal("queued uncertainty did not survive ledger recovery")
			}
			r.Disconnect(p.ID) // repeated cleanup must not append another outcome
			fresh := makeSchedulerProvider(t, r, p.ID, autopilotTestTarget, 100)
			fresh.mu.Lock()
			inherited := fresh.autopilotPending != nil || !fresh.autopilotControlUntil.IsZero() || fresh.autopilotControlRevision != ""
			fresh.mu.Unlock()
			if inherited || r.HandleAutopilotStatus(p.ID, p, &protocol.ModelAutopilotStatusMessage{CommandID: command.CommandID, Status: protocol.LoadModelStatusStarted}) {
				t.Fatal("old reservation/control authority crossed the reconnect boundary")
			}
			records, err := ledger.AutopilotRecords(context.Background(), time.Time{}, 100)
			if err != nil {
				t.Fatal(err)
			}
			uncertain := 0
			for _, record := range records {
				if record.Phase != "uncertain" {
					continue
				}
				uncertain++
				if record.CommandID != command.CommandID || record.ProviderID != p.ID || record.Reason != command.Reason ||
					record.Load != autopilotTestTarget || !slices.Equal(record.Before, []string{autopilotTestDonor}) ||
					!slices.Equal(record.Unload, []string{autopilotTestDonor}) || record.After != nil || record.ElapsedMS < 0 {
					t.Fatalf("uncertainty lost owned metadata or claimed a rollback: %+v", record)
				}
			}
			if uncertain != 1 {
				t.Fatalf("disconnect uncertainty missing or duplicated: %+v", records)
			}
		})
	}
}

func TestAutopilotDisconnectDoesNotReopenProvenUnsentOrReconciledCommands(t *testing.T) {
	for _, unsent := range []bool{true, false} {
		t.Run(map[bool]string{true: "proven unsent", false: "reconciled terminal"}[unsent], func(t *testing.T) {
			r, c, now := newAutopilotControllerTest(t, false)
			p := autopilotControllerProvider(t, r, "completed", now, autopilotTestDonor)
			w := autopilotDisconnectWriter(t, p, unsent)
			if summary := c.tick(now); summary.Issued != 1 {
				t.Fatal("baseline did not reserve a real command")
			}
			if !unsent {
				<-w.control // lease
				var command protocol.ModelAutopilotMessage
				if err := json.Unmarshal((<-w.control).data, &command); err != nil {
					t.Fatal(err)
				}
				state := autopilotControllerState(autopilotTestTarget)
				state.SessionID = p.ID
				state.LastCommandID, state.LastCommandStatus = command.CommandID, protocol.LoadModelStatusSucceeded
				r.Heartbeat(p.ID, &protocol.HeartbeatMessage{Status: "idle", BackendCapacity: autopilotControllerCapacity(11, autopilotTestTarget),
					ModelAutopilot: state, WarmModels: []string{autopilotTestTarget}})
			}
			p.mu.Lock()
			pending := p.autopilotPending
			p.mu.Unlock()
			if pending != nil {
				t.Fatal("proven unsent or capacity-reconciled operation still pending")
			}
			r.Disconnect(p.ID)
			if !r.flushAutopilotEvents() {
				t.Fatal("outcome ledger flush failed")
			}
			ledger, _ := store.As[store.AutopilotStore](r.store)
			records, err := ledger.AutopilotRecords(context.Background(), time.Time{}, 100)
			if err != nil {
				t.Fatal(err)
			}
			terminal := protocol.LoadModelStatusSucceeded
			if unsent {
				terminal = protocol.LoadModelStatusFailed
			}
			terminals := 0
			for _, record := range records {
				if record.Phase == "uncertain" {
					t.Fatalf("disconnect reopened a proven outcome: %+v", record)
				}
				if record.Phase == terminal {
					terminals++
					if unsent && !slices.Equal(record.Before, record.After) {
						t.Fatal("proven unsent failure changed residency evidence")
					}
				}
			}
			if terminals != 1 {
				t.Fatalf("disconnect lost the already proven outcome: %+v", records)
			}
		})
	}
}

func TestAutopilotGuardedDisconnectDoesNotMarkCurrentSessionUncertain(t *testing.T) {
	r, c, now := newAutopilotControllerTest(t, false)
	p := autopilotControllerProvider(t, r, "current", now, autopilotTestDonor)
	autopilotDisconnectWriter(t, p, false)
	if summary := c.tick(now); summary.Issued != 1 {
		t.Fatal("baseline did not enqueue a real command")
	}
	for _, guard := range []struct {
		expected *Provider
		timeout  time.Duration
	}{{p, DefaultProviderHeartbeatTimeout}, {&Provider{ID: p.ID}, -1}} {
		if r.disconnectProvider(p.ID, guard.expected, guard.timeout, protocol.CoordinatorCauseProviderDisconnected) {
			t.Fatal("fresh or replacement session passed the guarded disconnect")
		}
	}
	p.mu.Lock()
	uncertain := p.autopilotPending == nil || p.autopilotPending.Uncertain
	p.mu.Unlock()
	if uncertain || r.GetProvider(p.ID) != p {
		t.Fatal("rejected cleanup changed pending command ownership")
	}
	if !r.flushAutopilotEvents() {
		t.Fatal("ledger flush failed")
	}
	ledger, _ := store.As[store.AutopilotStore](r.store)
	records, err := ledger.AutopilotRecords(context.Background(), time.Time{}, 100)
	if err != nil || len(records) != 1 || records[0].Phase != "reserved" {
		t.Fatalf("rejected cleanup appended a false uncertain outcome: records=%+v error=%v", records, err)
	}
}

func TestAutopilotShutdownFlushPersistsJoinedDisconnectUncertainty(t *testing.T) {
	r, c, now := newAutopilotControllerTest(t, false)
	p := autopilotControllerProvider(t, r, "shutdown", now, autopilotTestDonor)
	autopilotDisconnectWriter(t, p, false)
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	stop := r.StartAutopilotController(ctx, c.config)
	t.Cleanup(stop)
	if summary := c.tick(now); summary.Issued != 1 {
		t.Fatal("baseline did not persist and enqueue a real command")
	}
	cancel() // main stops ticks before closing and joining provider handlers
	r.Disconnect(p.ID)
	ledger, _ := store.As[store.AutopilotStore](r.store)
	records, err := ledger.AutopilotRecords(context.Background(), time.Time{}, 100)
	if err != nil || len(records) != 1 || records[0].Phase != "reserved" {
		t.Fatalf("disconnect must only queue uncertainty: records=%+v error=%v", records, err)
	}
	stop() // deferred stop follows joined provider teardown, before store close
	records, err = ledger.AutopilotRecords(context.Background(), time.Time{}, 100)
	uncertain := 0
	for _, record := range records {
		if record.Phase == "uncertain" {
			uncertain++
		}
	}
	if err != nil || len(records) != 2 || uncertain != 1 {
		t.Fatalf("final shutdown flush lost joined disconnect uncertainty: records=%+v error=%v", records, err)
	}
}
