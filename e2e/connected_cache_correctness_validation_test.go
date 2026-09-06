package e2e

import (
	"math"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/e2e/testbed"
	"github.com/stretchr/testify/require"
)

func TestConnectedCorrectnessRequiresExplicitScope(t *testing.T) {
	in := connectedHostInputFixture()
	require.NoError(t, validateConnectedRunScope(in, false))
	require.Error(t, validateConnectedRunScope(in, true))
	in.CorrectnessOnly = true
	require.NoError(t, validateConnectedRunScope(in, true))
	require.Error(t, validateConnectedRunScope(in, false))
	in.Providers = nil
	require.Error(t, validateConnectedRunScope(in, true))
}

func TestConnectedCorrectnessSeparatesHeatFromReadiness(t *testing.T) {
	target := connectedHostInputFixture().Providers[0]
	observation := testbed.HostObservation{
		HardwareModel: target.HardwareModel, MemoryBytes: target.MemoryBytes,
		GPUTemperature: 42.58835220336914, Load1: 5.56103515625,
		FreeBytes: 200 << 30, OwnedProcesses: []int{123},
	}
	require.Error(t, connectedHostEntryReady(observation, target, false))
	require.NoError(t, connectedHostEntryReady(observation, target, true))
	require.Error(t, observation.CleanupComplete())
	for name, mutate := range map[string]func(*testbed.HostObservation){
		"unexpected_process": func(value *testbed.HostObservation) { value.UnexpectedProcesses = []int{456} },
		"missing_provider":   func(value *testbed.HostObservation) { value.OwnedProcesses = nil },
		"hardware_changed":   func(value *testbed.HostObservation) { value.HardwareModel = "other" },
		"memory_changed":     func(value *testbed.HostObservation) { value.MemoryBytes++ },
		"disk_floor":         func(value *testbed.HostObservation) { value.FreeBytes = 100 << 30 },
		"invalid_temp":       func(value *testbed.HostObservation) { value.GPUTemperature = math.NaN() },
		"infinite_temp":      func(value *testbed.HostObservation) { value.GPUTemperature = math.Inf(1) },
		"negative_temp":      func(value *testbed.HostObservation) { value.GPUTemperature = -1 },
		"invalid_load":       func(value *testbed.HostObservation) { value.Load1 = math.NaN() },
		"infinite_load":      func(value *testbed.HostObservation) { value.Load1 = math.Inf(1) },
		"negative_load":      func(value *testbed.HostObservation) { value.Load1 = -1 },
	} {
		t.Run(name, func(t *testing.T) {
			changed := observation
			mutate(&changed)
			require.Error(t, connectedHostEntryReady(changed, target, true))
		})
	}
}

func TestConnectedCorrectnessWaitsForQuiescentCapacity(t *testing.T) {
	slots := []connectedSlot{{Capacity: &protocol.BackendCapacity{Slots: []protocol.BackendSlotCapacity{{Model: "target"}}}}}
	require.True(t, connectedSlotsQuiescent(slots, 1, "target"))
	require.False(t, connectedSlotsQuiescent(slots, 2, "target"))
	require.False(t, connectedSlotsQuiescent(nil, 0, "target"))
	for name, capacity := range map[string]protocol.BackendSlotCapacity{
		"running":      {Model: "target", NumRunning: 1},
		"waiting":      {Model: "target", NumWaiting: 1},
		"active":       {Model: "target", ActiveTokens: 1},
		"wrong_model":  {Model: "other"},
		"missing_slot": {},
	} {
		t.Run(name, func(t *testing.T) {
			slots[0].Capacity.Slots[0] = capacity
			require.False(t, connectedSlotsQuiescent(slots, 1, "target"))
		})
	}
	slots[0].Capacity = nil
	require.False(t, connectedSlotsQuiescent(slots, 1, "target"))
}
