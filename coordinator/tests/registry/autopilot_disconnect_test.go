package registry_test

import (
	"context"
	"encoding/json"
	"errors"
	"slices"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/autopilotstate"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/providerwrite"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
	"nhooyr.io/websocket"
)

type disconnectAutopilotStore struct {
	*memory.MemoryStore
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

type autopilotDeliveryWriters map[string]*writerFixture

func (writers autopilotDeliveryWriters) Open(id string, _ *websocket.Conn) *providerwrite.Writer {
	if writer := writers[id]; writer != nil {
		return writer.Writer
	}
	return nil
}

func (f *writerFixture) readFrame(control bool) []byte {
	return f.executeFrame(f.take(control))
}

func (f *writerFixture) executeFrame(req *providerwrite.Request) []byte {
	f.Execute(req)
	req.Publish()
	f.transport.mu.Lock()
	defer f.transport.mu.Unlock()
	return append([]byte(nil), f.transport.last...)
}

func autopilotDisconnectWriter(t *testing.T, connections autopilotDeliveryWriters, id string, full bool) *writerFixture {
	t.Helper()
	w := newWriterFixture(0, 2, nil, nil, nil, nil)
	if full {
		w.offer(providerwrite.NewFrame(nil, nil), true)
		w.offer(providerwrite.NewFrame(nil, nil), true)
	}
	connections[id] = w
	t.Cleanup(func() { w.Close(); w.Run() })
	return w
}

func TestAutopilotDisconnectQueuesDurableUncertaintyWithoutLedgerIO(t *testing.T) {
	for _, status := range []string{"reserved", protocol.LoadModelStatusStarted, protocol.LoadModelStatusSucceeded} {
		t.Run(status, func(t *testing.T) {
			connections := autopilotDeliveryWriters{}
			r, c, now := newAutopilotControllerTest(t, false, func(deps *production.Dependencies) {
				deps.Connections = connections
			})
			ledger := &disconnectAutopilotStore{MemoryStore: memory.NewMemory(store.Config{})}
			r.SetStore(ledger)
			w := autopilotDisconnectWriter(t, connections, "disconnecting", false)
			p := autopilotControllerProvider(t, r, "disconnecting", now, autopilotTestDonor)
			p.Mu().Lock()
			p.ModelAutopilot.MaxModelSlots = 1 // force the command to name a donor victim
			p.Mu().Unlock()
			if summary := c.Tick(now); summary.Issued != 1 || w.lanes.Depth(true) != 2 {
				t.Fatalf("real lease and residency command were not reserved/enqueued: %+v", summary)
			}
			var control protocol.ModelAutopilotControl
			if err := json.Unmarshal(w.readFrame(true), &control); err != nil || !control.Enabled || control.ObserveOnly {
				t.Fatalf("invalid live control bookkeeping: %+v error=%v", control, err)
			}
			var command protocol.ModelAutopilotMessage
			if err := json.Unmarshal(w.readFrame(true), &command); err != nil {
				t.Fatal(err)
			}
			if status != "reserved" && !r.HandleAutopilotStatus(p.ID, p, &protocol.ModelAutopilotStatusMessage{CommandID: command.CommandID, Status: status}) {
				t.Fatal("matching command acknowledgement rejected")
			}
			if !r.events.Flush(ledger, testLogger()) {
				t.Fatal("pre-disconnect ledger flush failed")
			}
			calls := ledger.calls.Load()
			ledger.unavailable.Store(true)
			r.Disconnect(p.ID)
			if ledger.calls.Load() != calls {
				t.Fatal("disconnect attempted synchronous ledger IO")
			}
			if r.GetProvider(p.ID) != nil || !w.Closed() || len(c.Fleet(now).Nodes) != 0 {
				t.Fatal("disconnect left the old session, writer or future capacity registered")
			}
			p.Mu().Lock()
			pending, present := r.states[p.ID].PrepareDelivery()
			if !present || !pending.Uncertain || pending.Command.CommandID != command.CommandID || pending.Status != status {
				p.Mu().Unlock()
				t.Fatal("disconnect discarded or falsified unresolved operation metadata")
			}
			if len(p.BackendCapacity.Slots) != 1 || p.BackendCapacity.Slots[0].Model != autopilotTestDonor {
				p.Mu().Unlock()
				t.Fatal("disconnect manufactured final residency")
			}
			pending.Command.ExpectedResidentModels[0] = "discarded-prior-array"
			pending.Command.UnloadModelIDs[0] = "discarded-unload-array"
			p.Mu().Unlock()
			if r.events.Flush(ledger, testLogger()) {
				t.Fatal("unavailable ledger accepted uncertainty")
			}
			ledger.unavailable.Store(false)
			if !r.events.Flush(ledger, testLogger()) {
				t.Fatal("queued uncertainty did not survive ledger recovery")
			}
			r.Disconnect(p.ID) // repeated cleanup must not append another outcome
			delete(connections, p.ID)
			fresh := makeSchedulerProvider(t, r.Registry, p.ID, autopilotTestTarget, 100)
			fresh.Mu().Lock()
			_, freshPending := r.states[fresh.ID].PrepareDelivery()
			inherited := freshPending || *r.leases[fresh.ID] != (autopilotstate.Lease{})
			fresh.Mu().Unlock()
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
			connections := autopilotDeliveryWriters{}
			r, c, now := newAutopilotControllerTest(t, false, func(deps *production.Dependencies) {
				deps.Connections = connections
			})
			w := autopilotDisconnectWriter(t, connections, "completed", unsent)
			p := autopilotControllerProvider(t, r, "completed", now, autopilotTestDonor)
			p.Mu().Lock()
			p.ModelAutopilot.MaxModelSlots = 1 // force the command to name a donor victim
			p.Mu().Unlock()
			if summary := c.Tick(now); summary.Issued != 1 {
				t.Fatal("baseline did not reserve a real command")
			}
			if !unsent {
				<-w.lanes.Receive(true) // lease
				var command protocol.ModelAutopilotMessage
				if err := json.Unmarshal(w.readFrame(true), &command); err != nil {
					t.Fatal(err)
				}
				state := autopilotControllerState(autopilotTestTarget)
				state.SessionID = p.ID
				state.LastCommandID, state.LastCommandStatus = command.CommandID, protocol.LoadModelStatusSucceeded
				r.Heartbeat(p.ID, &protocol.HeartbeatMessage{Status: "idle", BackendCapacity: autopilotControllerCapacity(11, autopilotTestTarget),
					ModelAutopilot: state, WarmModels: []string{autopilotTestTarget}})
			}
			p.Mu().Lock()
			_, pending := r.states[p.ID].PrepareDelivery()
			p.Mu().Unlock()
			if pending {
				t.Fatal("proven unsent or capacity-reconciled operation still pending")
			}
			r.Disconnect(p.ID)
			if !r.events.Flush(r.store, testLogger()) {
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
	connections := autopilotDeliveryWriters{}
	var lifecycle *production.ConnectionLifecycle
	r, c, now := newAutopilotControllerTest(t, false, func(deps *production.Dependencies) {
		deps.Connections = connections
		deps.ConnectionLifecycle = func(actual *production.ConnectionLifecycle) production.ConnectionMaintenance {
			lifecycle = actual
			return actual
		}
	})
	autopilotDisconnectWriter(t, connections, "current", false)
	p := autopilotControllerProvider(t, r, "current", now, autopilotTestDonor)
	p.Mu().Lock()
	p.ModelAutopilot.MaxModelSlots = 1 // force the command to name a donor victim
	p.Mu().Unlock()
	if summary := c.Tick(now); summary.Issued != 1 {
		t.Fatal("baseline did not enqueue a real command")
	}
	for _, guard := range []struct {
		expected *production.Provider
		timeout  time.Duration
	}{{p, production.DefaultProviderHeartbeatTimeout}, {&production.Provider{ID: p.ID}, -1}} {
		if lifecycle.Disconnect(p.ID, guard.expected, guard.timeout, protocol.CoordinatorCauseProviderDisconnected) {
			t.Fatal("fresh or replacement session passed the guarded disconnect")
		}
	}
	p.Mu().Lock()
	pending, present := r.states[p.ID].PrepareDelivery()
	uncertain := !present || pending.Uncertain
	p.Mu().Unlock()
	if uncertain || r.GetProvider(p.ID) != p {
		t.Fatal("rejected cleanup changed pending command ownership")
	}
	if !r.events.Flush(r.store, testLogger()) {
		t.Fatal("ledger flush failed")
	}
	ledger, _ := store.As[store.AutopilotStore](r.store)
	records, err := ledger.AutopilotRecords(context.Background(), time.Time{}, 100)
	if err != nil || len(records) != 1 || records[0].Phase != "reserved" {
		t.Fatalf("rejected cleanup appended a false uncertain outcome: records=%+v error=%v", records, err)
	}
}

func TestAutopilotShutdownFlushPersistsJoinedDisconnectUncertainty(t *testing.T) {
	connections := autopilotDeliveryWriters{}
	r, c, now := newAutopilotControllerTest(t, false, func(deps *production.Dependencies) {
		deps.Connections = connections
	})
	autopilotDisconnectWriter(t, connections, "shutdown", false)
	p := autopilotControllerProvider(t, r, "shutdown", now, autopilotTestDonor)
	p.Mu().Lock()
	p.ModelAutopilot.MaxModelSlots = 1 // force the command to name a donor victim
	p.Mu().Unlock()
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	stop := r.StartAutopilotController(ctx, r.cfg)
	t.Cleanup(stop)
	if summary := c.Tick(now); summary.Issued != 1 {
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
