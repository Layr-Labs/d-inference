package registry_test

import (
	"context"
	"errors"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/registry/autopilot"
	"github.com/eigeninference/d-inference/coordinator/store"
)

func autopilotMachineControlActive(r *autopilotFixture, p *production.Provider) bool {
	p.Mu().Lock()
	defer p.Mu().Unlock()
	return r.states[p.ID].ControlActive(p.ModelAutopilot, p.ID, time.Now())
}

func acknowledgeAutopilotMachine(r *autopilotFixture, p *production.Provider, control protocol.ModelAutopilotControl, seq uint64) time.Time {
	p.Mu().Lock()
	state := autopilot.CloneState(p.ModelAutopilot)
	metrics := p.SystemMetrics
	p.Mu().Unlock()
	state.Active, state.ObserveOnly = control.Enabled && !control.ObserveOnly, control.ObserveOnly
	state.SessionID, state.Revision = control.SessionID, control.Revision
	residents := autopilot.ResidentIDs(state)
	capacity := autopilotControllerCapacity(seq, residents...)
	if len(residents) == 0 {
		// With no slots, a real process sample establishes capacity freshness.
		capacity.Telemetry = &protocol.CapacityTelemetry{ProcessMemory: &protocol.ProcessMemoryTelemetry{
			Generation: 1, SampleSeq: seq, PolicyEpoch: 1,
			CapBytes: 56 << 30, ActivationReserveBytes: 6 << 30, ActiveBytes: 2 << 30, RemainingBytes: 48 << 30,
		}}
	}
	r.Heartbeat(p.ID, &protocol.HeartbeatMessage{Status: "idle", BackendCapacity: capacity, ModelAutopilot: state, WarmModels: residents, SystemMetrics: metrics})
	return time.Now()
}

func autopilotMachineStatus(t *testing.T, r *autopilotFixture, machineID string) production.MachineAutopilotStatus {
	t.Helper()
	rows, err := r.ListMachineAutopilot(context.Background(), "", 200)
	if err != nil {
		t.Fatal(err)
	}
	for _, row := range rows {
		if row.MachineID == machineID {
			return row
		}
	}
	t.Fatalf("canonical machine %s missing from policy inventory", machineID)
	return production.MachineAutopilotStatus{}
}

var errAutopilotMachineStore = errors.New("machine policy store unavailable")

type autopilotCapabilityStore struct {
	store.Store
	unavailable atomic.Bool
}

func (s *autopilotCapabilityStore) Unwrap() store.Store {
	if s.unavailable.Load() {
		return nil
	}
	return s.Store
}

// The real backend remains the only source of policy rows. The probe can delay
// a completed read or report a failure after a real write has committed.
type autopilotMachineStoreProbe struct {
	store.Store
	store.MachineAutopilotStore
	failRead, failWrite     atomic.Bool
	blockRead               atomic.Bool
	readEntered, readResume chan struct{}
	writeEntered            chan struct{}
	resumeOnce              sync.Once
}

func newAutopilotMachineStoreProbe(t *testing.T, backend store.Store) *autopilotMachineStoreProbe {
	t.Helper()
	settings, ok := store.As[store.MachineAutopilotStore](backend)
	if !ok {
		t.Fatal("fixture backend has no machine policy capability")
	}
	return &autopilotMachineStoreProbe{
		Store: backend, MachineAutopilotStore: settings,
		readEntered: make(chan struct{}), readResume: make(chan struct{}), writeEntered: make(chan struct{}, 1),
	}
}

func (s *autopilotMachineStoreProbe) Unwrap() store.Store { return s.Store }

func (s *autopilotMachineStoreProbe) resumeRead() {
	s.resumeOnce.Do(func() { close(s.readResume) })
}

func (s *autopilotMachineStoreProbe) LiveMachineAutopilotSettings(ctx context.Context) ([]store.MachineAutopilotSetting, error) {
	rows, err := s.MachineAutopilotStore.LiveMachineAutopilotSettings(ctx)
	if err != nil {
		return nil, err
	}
	if s.blockRead.CompareAndSwap(true, false) {
		close(s.readEntered)
		select {
		case <-s.readResume:
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}
	if s.failRead.Load() {
		return nil, errAutopilotMachineStore
	}
	return rows, nil
}

func (s *autopilotMachineStoreProbe) SetMachineAutopilotDesiredMode(ctx context.Context, machineID string, mode store.MachineAutopilotMode) (store.MachineAutopilotSetting, error) {
	select {
	case s.writeEntered <- struct{}{}:
	default:
	}
	setting, err := s.MachineAutopilotStore.SetMachineAutopilotDesiredMode(ctx, machineID, mode)
	if err == nil && s.failWrite.Load() {
		return store.MachineAutopilotSetting{}, errAutopilotMachineStore
	}
	return setting, err
}
