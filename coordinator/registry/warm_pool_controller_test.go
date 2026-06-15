package registry

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

func testWarmPoolConfig() WarmPoolConfig {
	return WarmPoolConfig{
		Enabled:                   true,
		ObserveOnly:               false,
		Interval:                  time.Second,
		MinDwell:                  0,
		QueueAgeThreshold:         2 * time.Second,
		CapacityRejectThreshold:   1,
		WarmSaturationThreshold:   0.8,
		TTFTMissThreshold:         1,
		SpeculativeStartThreshold: 1,
		SpeculativeWinThreshold:   1,
		ColdDispatchThreshold:     1,
		LoadDurationThreshold:     time.Second,
		MaxLoadsPerTick:           1,
		MaxGlobalPendingLoads:     10,
	}
}

func makeWarmPoolColdProvider(t *testing.T, reg *Registry, id, model string, decodeTPS float64, totalMemory, activeMemory float64) *Provider {
	t.Helper()
	p := makeSchedulerProvider(t, reg, id, model, decodeTPS)
	p.mu.Lock()
	p.BackendCapacity = &protocol.BackendCapacity{
		TotalMemoryGB:     totalMemory,
		GPUMemoryActiveGB: activeMemory,
		Slots: []protocol.BackendSlotCapacity{
			{Model: "other-model", State: "idle"},
		},
	}
	p.mu.Unlock()
	return p
}

func captureWarmPoolLoads(reg *Registry) *[]modelLoadAction {
	var sent []modelLoadAction
	reg.loadModelSender = func(providerID, modelID string) error {
		sent = append(sent, modelLoadAction{providerID: providerID, modelID: modelID})
		return nil
	}
	return &sent
}

func TestWarmPoolSaturatedWarmProviderRaisesTargetAndSendsBoundedLoad(t *testing.T) {
	reg := New(testLogger())
	model := "warm-pool-saturated"
	warm := makeSchedulerProvider(t, reg, "warm", model, 80)
	cold := makeWarmPoolColdProvider(t, reg, "cold", model, 80, 64, 8)
	warm.mu.Lock()
	warm.BackendCapacity.Slots[0].MaxConcurrency = 1
	warm.BackendCapacity.Slots[0].NumRunning = 1
	warm.mu.Unlock()

	reg.ConfigureWarmPool(testWarmPoolConfig())
	sent := captureWarmPoolLoads(reg)
	reg.RecordWarmPoolCapacityReject(model)

	snaps := reg.warmPool.tick(time.Now())
	if len(*sent) != 1 {
		t.Fatalf("sent loads = %d, want 1", len(*sent))
	}
	if (*sent)[0].providerID != cold.ID || (*sent)[0].modelID != model {
		t.Fatalf("sent %+v, want cold provider/model", (*sent)[0])
	}
	if len(snaps) == 0 || snaps[0].TargetWarm < 2 || len(snaps[0].Actions) != 1 {
		t.Fatalf("snapshot = %+v, want target>=2 with one action", snaps)
	}
}

func TestWarmPoolCapacityRejectRaisesTargetWithoutQueue(t *testing.T) {
	reg := New(testLogger())
	model := "warm-pool-capacity"
	makeSchedulerProvider(t, reg, "warm", model, 80)
	makeWarmPoolColdProvider(t, reg, "cold", model, 80, 64, 8)
	reg.ConfigureWarmPool(testWarmPoolConfig())
	sent := captureWarmPoolLoads(reg)

	reg.RecordWarmPoolCapacityReject(model)
	reg.warmPool.tick(time.Now())

	if len(*sent) != 1 {
		t.Fatalf("sent loads = %d, want 1", len(*sent))
	}
}

func TestWarmPoolQueueAgePressureRaisesTarget(t *testing.T) {
	reg := New(testLogger())
	model := "warm-pool-queue-age"
	makeSchedulerProvider(t, reg, "warm", model, 80)
	makeWarmPoolColdProvider(t, reg, "cold", model, 80, 64, 8)
	reg.ConfigureWarmPool(testWarmPoolConfig())
	sent := captureWarmPoolLoads(reg)

	reg.RecordWarmPoolQueueEnqueued(model, 1, 3*time.Second)
	reg.warmPool.tick(time.Now())

	if len(*sent) != 1 {
		t.Fatalf("sent loads = %d, want 1", len(*sent))
	}
}

func TestWarmPoolNoPressureForLongActiveDecodeAlone(t *testing.T) {
	reg := New(testLogger())
	model := "warm-pool-active-only"
	warm := makeSchedulerProvider(t, reg, "warm", model, 80)
	makeWarmPoolColdProvider(t, reg, "cold", model, 80, 64, 8)
	warm.mu.Lock()
	warm.BackendCapacity.Slots[0].NumRunning = 1
	warm.mu.Unlock()
	reg.ConfigureWarmPool(testWarmPoolConfig())
	sent := captureWarmPoolLoads(reg)

	snaps := reg.warmPool.tick(time.Now())

	if len(*sent) != 0 {
		t.Fatalf("sent loads = %d, want 0", len(*sent))
	}
	if len(snaps) == 0 || snaps[0].TargetWarm != 1 {
		t.Fatalf("snapshot = %+v, want target 1", snaps)
	}
}

func TestWarmPoolSkipsIneligibleProviders(t *testing.T) {
	reg := New(testLogger())
	model := "warm-pool-skip"
	makeSchedulerProvider(t, reg, "warm", model, 80)
	priv := makeWarmPoolColdProvider(t, reg, "private", model, 80, 64, 8)
	untrusted := makeWarmPoolColdProvider(t, reg, "untrusted", model, 80, 64, 8)
	stale := makeWarmPoolColdProvider(t, reg, "stale", model, 80, 64, 8)
	critical := makeWarmPoolColdProvider(t, reg, "critical", model, 80, 64, 8)
	active := makeWarmPoolColdProvider(t, reg, "active", model, 80, 64, 8)
	pending := makeWarmPoolColdProvider(t, reg, "pending", model, 80, 64, 8)
	good := makeWarmPoolColdProvider(t, reg, "good", model, 80, 64, 8)

	priv.mu.Lock()
	priv.PrivateOnly = true
	priv.mu.Unlock()
	untrusted.mu.Lock()
	untrusted.Status = StatusUntrusted
	untrusted.mu.Unlock()
	stale.mu.Lock()
	stale.LastChallengeVerified = time.Now().Add(-10 * time.Minute)
	stale.mu.Unlock()
	critical.mu.Lock()
	critical.SystemMetrics.ThermalState = "critical"
	critical.mu.Unlock()
	active.AddPending(&PendingRequest{RequestID: "active-req", Model: "other-model"})
	reg.reservePendingModelLoads([]modelLoadAction{{providerID: pending.ID, modelID: model}}, time.Now())

	reg.ConfigureWarmPool(testWarmPoolConfig())
	sent := captureWarmPoolLoads(reg)
	reg.RecordWarmPoolCapacityReject(model)
	reg.warmPool.tick(time.Now())

	if len(*sent) != 1 {
		t.Fatalf("sent loads = %d, want 1", len(*sent))
	}
	if (*sent)[0].providerID != good.ID {
		t.Fatalf("selected provider = %q, want good", (*sent)[0].providerID)
	}
}

func TestWarmPoolPicksBetterIdleProvider(t *testing.T) {
	reg := New(testLogger())
	model := "warm-pool-score"
	makeSchedulerProvider(t, reg, "warm", model, 80)
	bad := makeWarmPoolColdProvider(t, reg, "bad", model, 40, 32, 28)
	good := makeWarmPoolColdProvider(t, reg, "good", model, 160, 128, 12)
	bad.mu.Lock()
	bad.SystemMetrics.ThermalState = "serious"
	bad.SystemMetrics.MemoryPressure = 0.7
	bad.mu.Unlock()

	reg.ConfigureWarmPool(testWarmPoolConfig())
	sent := captureWarmPoolLoads(reg)
	reg.RecordWarmPoolCapacityReject(model)
	reg.warmPool.tick(time.Now())

	if len(*sent) != 1 {
		t.Fatalf("sent loads = %d, want 1", len(*sent))
	}
	if (*sent)[0].providerID != good.ID {
		t.Fatalf("selected provider = %q, want %q", (*sent)[0].providerID, good.ID)
	}
}
