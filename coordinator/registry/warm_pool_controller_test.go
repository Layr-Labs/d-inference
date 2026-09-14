package registry

import (
	"fmt"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/env"
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

	snaps := reg.warmPool.Tick(time.Now())
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
	reg.warmPool.Tick(time.Now())

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
	reg.warmPool.Tick(time.Now())

	if len(*sent) != 1 {
		t.Fatalf("sent loads = %d, want 1", len(*sent))
	}
}

func TestTriggerWarmPoolRespondsToQueuePressureImmediately(t *testing.T) {
	reg := New(testLogger())
	model := "warm-pool-immediate-queue"
	makeSchedulerProvider(t, reg, "warm", model, 80)
	makeWarmPoolColdProvider(t, reg, "cold", model, 80, 64, 8)
	cfg := testWarmPoolConfig()
	cfg.QueueAgeThreshold = 0
	reg.ConfigureWarmPool(cfg)
	sent := captureWarmPoolLoads(reg)

	reg.RecordWarmPoolQueueEnqueued(model, 1, 0)
	snaps := reg.TriggerWarmPool()

	if len(*sent) != 1 {
		t.Fatalf("sent loads = %d, want 1", len(*sent))
	}
	if len(snaps) == 0 || snaps[0].QueueDepth != 1 || len(snaps[0].Actions) != 1 {
		t.Fatalf("snapshot = %+v, want immediate queue-pressure action", snaps)
	}
}

func TestRequestWarmPoolTriggerCoalescesBursts(t *testing.T) {
	reg := New(testLogger())
	reg.ConfigureWarmPool(testWarmPoolConfig())

	if !reg.RequestWarmPoolTrigger() {
		t.Fatal("first trigger should enqueue a warm-pool tick")
	}
	for i := 0; i < 10; i++ {
		if reg.RequestWarmPoolTrigger() {
			t.Fatalf("trigger %d was accepted despite an already pending tick", i+2)
		}
	}
	if got := reg.warmPool.PendingTriggers(); got != 1 {
		t.Fatalf("pending triggers = %d, want 1", got)
	}
}

func TestWarmPoolQueueClearStopsStaleQueueLoads(t *testing.T) {
	reg := New(testLogger())
	model := "warm-pool-clear-queue"
	makeSchedulerProvider(t, reg, "warm", model, 80)
	makeWarmPoolColdProvider(t, reg, "cold-a", model, 80, 64, 8)
	makeWarmPoolColdProvider(t, reg, "cold-b", model, 80, 64, 8)
	cfg := testWarmPoolConfig()
	cfg.QueueAgeThreshold = 0
	cfg.MaxGlobalPendingLoads = 10
	reg.ConfigureWarmPool(cfg)
	sent := captureWarmPoolLoads(reg)

	reg.RecordWarmPoolQueueEnqueued(model, 1, 0)
	reg.TriggerWarmPool()
	if len(*sent) != 1 {
		t.Fatalf("sent loads after queue pressure = %d, want 1", len(*sent))
	}

	reg.RecordWarmPoolQueueCleared(model)
	snaps := reg.TriggerWarmPool()
	if len(*sent) != 1 {
		t.Fatalf("sent loads after clearing queue = %d, want still 1", len(*sent))
	}
	if len(snaps) == 0 || snaps[0].QueueDepth != 0 || len(snaps[0].Actions) != 0 {
		t.Fatalf("snapshot after clear = %+v, want no queue-driven action", snaps)
	}
}

// TestWarmPoolEnvDefaultIsActiveAndSendsLoads pins the deploy-critical default:
// with NO warm-pool env set, ReadConfig yields an ACTIVE controller whose ticks
// actually issue load_model commands (not observe-only planning).
func TestWarmPoolEnvDefaultIsActiveAndSendsLoads(t *testing.T) {
	clearWarmPoolEnv(t)
	reg := New(testLogger())
	model := "warm-pool-env-default"
	makeSchedulerProvider(t, reg, "warm", model, 80)
	makeWarmPoolColdProvider(t, reg, "cold", model, 80, 64, 8)
	cfg := ReadConfig().WarmPool
	if cfg.ObserveOnly {
		t.Fatal("ObserveOnly = true with env unset, want false (active)")
	}
	reg.ConfigureWarmPool(cfg)
	sent := captureWarmPoolLoads(reg)

	reg.RecordWarmPoolCapacityReject(model)
	snaps := reg.warmPool.Tick(time.Now())

	if len(*sent) != 1 {
		t.Fatalf("sent loads = %d, want 1 with the env-default (active) config", len(*sent))
	}
	if len(snaps) == 0 || snaps[0].ObserveOnly {
		t.Fatalf("snapshot = %+v, want active (ObserveOnly=false)", snaps)
	}
}

// TestWarmPoolEnvObserveOnlyOverridePreserved pins the operator override:
// EIGENINFERENCE_WARM_POOL_OBSERVE_ONLY=true keeps planning ticks side-effect
// free (decisions computed, no load_model sent).
func TestWarmPoolEnvObserveOnlyOverridePreserved(t *testing.T) {
	clearWarmPoolEnv(t)
	t.Setenv(env.EnvPrefix+"_WARM_POOL_OBSERVE_ONLY", "true")
	reg := New(testLogger())
	model := "warm-pool-env-observe"
	makeSchedulerProvider(t, reg, "warm", model, 80)
	makeWarmPoolColdProvider(t, reg, "cold", model, 80, 64, 8)
	reg.ConfigureWarmPool(ReadConfig().WarmPool)
	sent := captureWarmPoolLoads(reg)

	reg.RecordWarmPoolCapacityReject(model)
	// The periodic ticker still runs planning passes in observe-only mode; they
	// must not issue loads. Hot-path triggers must be rejected outright.
	snaps := reg.warmPool.Tick(time.Now())

	if len(*sent) != 0 {
		t.Fatalf("sent loads = %d, want 0 in observe-only mode", len(*sent))
	}
	if len(snaps) == 0 || !snaps[0].ObserveOnly {
		t.Fatalf("snapshot = %+v, want ObserveOnly=true", snaps)
	}
	if reg.RequestWarmPoolTrigger() {
		t.Fatal("RequestWarmPoolTrigger accepted in observe-only mode, want rejection")
	}
}

func TestTriggerWarmPoolObserveOnlyDoesNotSendLoads(t *testing.T) {
	reg := New(testLogger())
	model := "warm-pool-observe-only"
	makeSchedulerProvider(t, reg, "warm", model, 80)
	makeWarmPoolColdProvider(t, reg, "cold", model, 80, 64, 8)
	cfg := testWarmPoolConfig()
	cfg.QueueAgeThreshold = 0
	cfg.ObserveOnly = true
	reg.ConfigureWarmPool(cfg)
	sent := captureWarmPoolLoads(reg)

	reg.RecordWarmPoolQueueEnqueued(model, 1, 0)
	snaps := reg.TriggerWarmPool()

	if len(*sent) != 0 {
		t.Fatalf("sent loads = %d, want 0 in observe-only mode", len(*sent))
	}
	if len(snaps) != 0 {
		t.Fatalf("snapshots = %+v, want no active trigger in observe-only mode", snaps)
	}
}

// TestWarmPoolDedicatedQueueSpillStillDrivesWarming pins the demand signals the
// controller sees now that dedicated-pool overflow QUEUES instead of fast-429ing:
// the admission preflight still records a capacity reject on the queue-spill
// branch, and the enqueue records queue pressure. Either signal alone must keep
// growing the dedicated pool — toward the WHOLE eligible dedicated set — and
// never target a mixed (non-dedicated) box.
func TestWarmPoolDedicatedQueueSpillStillDrivesWarming(t *testing.T) {
	signals := map[string]func(reg *Registry, model string){
		"capacity_reject": func(reg *Registry, model string) {
			reg.RecordWarmPoolCapacityReject(model)
		},
		"queue_pressure_only": func(reg *Registry, model string) {
			reg.RecordWarmPoolQueueEnqueued(model, 3, 3*time.Second)
		},
	}
	for name, feed := range signals {
		t.Run(name, func(t *testing.T) {
			reg := New(testLogger())
			reg.SetDedicatedModels([]string{"gemma-4"})
			makeSchedulerProvider(t, reg, "warm-dedicated", gemmaBuild, 80)
			coldA := makeWarmPoolColdProvider(t, reg, "cold-dedicated-a", gemmaBuild, 80, 64, 8)
			coldB := makeWarmPoolColdProvider(t, reg, "cold-dedicated-b", gemmaBuild, 80, 64, 8)
			mixed := makeWarmPoolColdProvider(t, reg, "cold-mixed", gemmaBuild, 80, 64, 8)
			addAdvertisedModel(mixed, qwenBuild)

			cfg := testWarmPoolConfig()
			cfg.MaxLoadsPerTick = 4
			reg.ConfigureWarmPool(cfg)
			sent := captureWarmPoolLoads(reg)

			feed(reg, gemmaBuild)
			snaps := reg.warmPool.Tick(time.Now())

			var snap WarmPoolSnapshot
			found := false
			for _, s := range snaps {
				if s.Model == gemmaBuild {
					snap = s
					found = true
					break
				}
			}
			if !found {
				t.Fatalf("no warm-pool snapshot for %q in %+v", gemmaBuild, snaps)
			}
			// Dedicated pool under demand pressure warms the whole eligible set:
			// 1 warm + 2 eligible cold (the mixed box is excluded).
			if snap.TargetWarm != 3 {
				t.Fatalf("TargetWarm = %d, want 3 (whole dedicated pool)", snap.TargetWarm)
			}
			if snap.EligibleCold != 2 {
				t.Fatalf("EligibleCold = %d, want 2 (mixed box excluded)", snap.EligibleCold)
			}
			if snap.ColdDisqualifiers["dedicated_excluded"] != 1 {
				t.Fatalf("ColdDisqualifiers = %v, want mixed box tallied as dedicated_excluded", snap.ColdDisqualifiers)
			}
			if len(*sent) != 2 {
				t.Fatalf("sent loads = %d, want 2 (both cold dedicated boxes)", len(*sent))
			}
			for _, action := range *sent {
				if action.providerID != coldA.ID && action.providerID != coldB.ID {
					t.Fatalf("load sent to %q, want only dedicated boxes", action.providerID)
				}
				if action.modelID != gemmaBuild {
					t.Fatalf("load model = %q, want %q", action.modelID, gemmaBuild)
				}
			}
		})
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

	snaps := reg.warmPool.Tick(time.Now())

	if len(*sent) != 0 {
		t.Fatalf("sent loads = %d, want 0", len(*sent))
	}
	if len(snaps) == 0 || snaps[0].TargetWarm != 1 {
		t.Fatalf("snapshot = %+v, want target 1", snaps)
	}
}

func TestWarmPoolMinWarmFloorLoadsWithoutPressure(t *testing.T) {
	reg := New(testLogger())
	model := "warm-pool-min-floor"
	makeSchedulerProvider(t, reg, "warm", model, 80)
	makeWarmPoolColdProvider(t, reg, "cold-a", model, 80, 64, 8)
	makeWarmPoolColdProvider(t, reg, "cold-b", model, 80, 64, 8)
	cfg := testWarmPoolConfig()
	cfg.MinWarmByModel = map[string]int{model: 3}
	reg.ConfigureWarmPool(cfg)
	sent := captureWarmPoolLoads(reg)

	snaps := reg.warmPool.Tick(time.Now())

	if len(snaps) != 1 {
		t.Fatalf("snapshots = %d, want 1", len(snaps))
	}
	if snaps[0].TargetWarm != 3 {
		t.Fatalf("TargetWarm = %d, want min floor 3", snaps[0].TargetWarm)
	}
	if len(*sent) != 1 {
		t.Fatalf("sent loads = %d, want 1 (bounded by MaxLoadsPerTick)", len(*sent))
	}
}

func TestWarmPoolMinWarmFloorCapsAtReachable(t *testing.T) {
	reg := New(testLogger())
	model := "warm-pool-min-floor-cap"
	makeSchedulerProvider(t, reg, "warm", model, 80)
	makeWarmPoolColdProvider(t, reg, "cold", model, 80, 64, 8)
	cfg := testWarmPoolConfig()
	cfg.MinWarmByModel = map[string]int{model: 5}
	reg.ConfigureWarmPool(cfg)

	snaps := reg.warmPool.Tick(time.Now())

	if len(snaps) != 1 {
		t.Fatalf("snapshots = %d, want 1", len(snaps))
	}
	if snaps[0].TargetWarm != 2 {
		t.Fatalf("TargetWarm = %d, want reachable cap 2", snaps[0].TargetWarm)
	}
}

func TestWarmPoolPressureLoadsBeforeMinWarmFloor(t *testing.T) {
	reg := New(testLogger())
	floorModel := "aaa-floor-model"
	pressureModel := "zzz-pressure-model"
	makeSchedulerProvider(t, reg, "floor-warm", floorModel, 80)
	floorCold := makeWarmPoolColdProvider(t, reg, "floor-cold", floorModel, 80, 64, 8)
	makeSchedulerProvider(t, reg, "pressure-warm", pressureModel, 80)
	pressureCold := makeWarmPoolColdProvider(t, reg, "pressure-cold", pressureModel, 80, 64, 8)
	cfg := testWarmPoolConfig()
	cfg.MaxLoadsPerTick = 1
	cfg.MaxLoadsPerTickCeiling = 1
	cfg.MinWarmByModel = map[string]int{floorModel: 2}
	reg.ConfigureWarmPool(cfg)
	sent := captureWarmPoolLoads(reg)
	reg.RecordWarmPoolCapacityReject(pressureModel)

	reg.warmPool.Tick(time.Now())

	if len(*sent) != 1 {
		t.Fatalf("sent loads = %d, want 1", len(*sent))
	}
	if (*sent)[0].providerID != pressureCold.ID || (*sent)[0].modelID != pressureModel {
		t.Fatalf("sent %+v, want pressure model/provider", (*sent)[0])
	}
	if (*sent)[0].providerID == floorCold.ID {
		t.Fatal("floor-only warmup consumed pressure load budget")
	}
}

// TestWarmPoolFleetSnapshotSplitsSoloAndServiceRates: the snapshot's
// soloDecodeTPS must come from the quality-cap solo resolver (static solo
// rate — here the registration benchmark, since no solo samples or seed
// exist), NOT the under-load slot EWMA, so warm targets use the same quality
// math as the admission cap. The EWMA still feeds serviceDecodeTPS/prefillTPS,
// which size E[S] (a request's actually-observed rates).
func TestWarmPoolFleetSnapshotSplitsSoloAndServiceRates(t *testing.T) {
	reg := New(testLogger())
	model := "warm-pool-observed-tps"
	p := makeSchedulerProvider(t, reg, "warm", model, 23)
	p.mu.Lock()
	p.BackendCapacity.Slots[0].ObservedDecodeTPS = 73
	p.BackendCapacity.Slots[0].ObservedPrefillTPS = 1000
	p.mu.Unlock()

	snap := reg.warmPoolFleetSnapshot(time.Now())[model]

	if snap.SoloDecodeTPS != 23 {
		t.Fatalf("soloDecodeTPS = %v, want static solo rate 23 (observed EWMA must not feed quality concurrency)", snap.SoloDecodeTPS)
	}
	if snap.ServiceDecodeTPS != 73 {
		t.Fatalf("serviceDecodeTPS = %v, want observed slot TPS 73", snap.ServiceDecodeTPS)
	}
	if snap.PrefillTPS != 1000 {
		t.Fatalf("prefillTPS = %v, want observed slot prefill TPS 1000", snap.PrefillTPS)
	}
}

func TestWarmPoolFleetSnapshotFallsBackToStaticTPS(t *testing.T) {
	reg := New(testLogger())
	model := "warm-pool-static-tps"
	makeSchedulerProvider(t, reg, "warm", model, 23)

	snap := reg.warmPoolFleetSnapshot(time.Now())[model]

	if snap.SoloDecodeTPS != 23 {
		t.Fatalf("soloDecodeTPS = %v, want static TPS 23", snap.SoloDecodeTPS)
	}
	if snap.PrefillTPS != 23*PrefillToDecodeRatio() {
		t.Fatalf("prefillTPS = %v, want static fallback %v", snap.PrefillTPS, 23*PrefillToDecodeRatio())
	}
}

// TestWarmPoolDiagnosticsSplitObservedAndSoloRates: E[S] (ServiceTime) still
// reflects the observed load-inclusive rates, while QualityConcurrency
// deliberately does NOT read the under-load EWMA — it is computed from the
// same static solo rate as the admission cap (postmortem layer 6: EWMA-fed
// planning and static-fed admission used to disagree). Static 23 tok/s at
// floor 15 → quality batch 1, no matter how high the current EWMA reads.
func TestWarmPoolDiagnosticsSplitObservedAndSoloRates(t *testing.T) {
	reg := New(testLogger())
	model := "warm-pool-observed-diagnostics"
	p := makeSchedulerProvider(t, reg, "warm", model, 23)
	p.mu.Lock()
	p.BackendCapacity.Slots[0].ObservedDecodeTPS = 73
	p.BackendCapacity.Slots[0].ObservedPrefillTPS = 1000
	p.mu.Unlock()

	cfg := testWarmPoolConfig()
	cfg.DecodeFloorTPS = 15
	cfg.AssumedPromptTokens = 512
	cfg.AssumedCompletionTokens = 256
	reg.ConfigureWarmPool(cfg)
	reg.RecordWarmPoolCapacityReject(model)

	snaps := reg.warmPool.Tick(time.Now())
	if len(snaps) != 1 {
		t.Fatalf("snapshots = %d, want 1", len(snaps))
	}
	snap := snaps[0]
	if snap.QualityConcurrency != 1 {
		t.Fatalf("QualityConcurrency = %d, want 1 from the static solo rate 23 (observed EWMA 73 must not inflate the quality batch)", snap.QualityConcurrency)
	}
	if snap.ServiceTime >= 10*time.Second {
		t.Fatalf("ServiceTime = %v, want observed rates to keep it below stale 12.8s", snap.ServiceTime)
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
	// Stale beyond challengeFreshnessMaxAge (16m as of W5b Fix 4) so the warm-pool
	// controller treats this provider's attestation as expired and skips it.
	stale.LastChallengeVerified = time.Now().Add(-20 * time.Minute)
	stale.mu.Unlock()
	critical.mu.Lock()
	critical.SystemMetrics.ThermalState = "critical"
	critical.mu.Unlock()
	active.AddPending(&PendingRequest{RequestID: "active-req", Model: "other-model"})
	reg.reservePendingModelLoads([]modelLoadAction{{providerID: pending.ID, modelID: model}}, time.Now())

	reg.ConfigureWarmPool(testWarmPoolConfig())
	sent := captureWarmPoolLoads(reg)
	reg.RecordWarmPoolCapacityReject(model)
	reg.warmPool.Tick(time.Now())

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
	reg.warmPool.Tick(time.Now())

	if len(*sent) != 1 {
		t.Fatalf("sent loads = %d, want 1", len(*sent))
	}
	if (*sent)[0].providerID != good.ID {
		t.Fatalf("selected provider = %q, want %q", (*sent)[0].providerID, good.ID)
	}
}

// --- Little's Law target math (pure, warm_pool_target.go) ---

func TestQualityConcurrencyFromDecodeFloor(t *testing.T) {
	k := effectiveTPSLoadFactor
	// solo 100, floor 15: B <= (100/15 - 1)/k, under the cap of 32 at any
	// measured k (20 at the legacy 0.27, 14 at the CBv2-re-fit 0.39).
	// strictQualityBatch reaches the same answer from the defining
	// inequality, so this pins the closed form, not the coefficient.
	if want, got := strictQualityBatch(100, 15, k, 32), qualityConcurrency(100, 15, k, 32, 4); got != want {
		t.Fatalf("qc(solo100,floor15,cap32) = %d, want %d (k=%.2f)", got, want, k)
	}
	// Capped by the provider concurrency limit.
	if got := qualityConcurrency(100, 15, k, 6, 4); got != 6 {
		t.Fatalf("qc capped = %d, want 6", got)
	}
	// Solo at/below floor -> only one request per provider keeps quality.
	if got := qualityConcurrency(10, 15, k, 8, 4); got != 1 {
		t.Fatalf("qc(solo10,floor15) = %d, want 1", got)
	}
	// Floor disabled -> constraint does not bind, return the cap.
	if got := qualityConcurrency(100, 0, k, 8, 4); got != 8 {
		t.Fatalf("qc(floor=0) = %d, want 8 (cap)", got)
	}
	// Unknown cap -> fallback concurrency.
	if got := qualityConcurrency(100, 0, k, 0, 4); got != 4 {
		t.Fatalf("qc(no cap) = %d, want 4 (fallback)", got)
	}
}

// --- Arrival-rate EWMA (warm_pool_state.go) ---

// --- Controller integration: Little's Law + demand-scaled ramp ---

func TestWarmPoolLittlesLawDemandScaledRamp(t *testing.T) {
	reg := New(testLogger())
	model := "warm-pool-littles-law"
	// One warm provider overloaded with 8 in-flight requests; with a 15 tok/s
	// floor and a 20 tok/s solo rate, per-provider quality concurrency is 1, so
	// Little's Law wants 8 warm providers to serve the in-flight load at quality.
	warm := makeSchedulerProvider(t, reg, "warm", model, 20)
	warm.mu.Lock()
	warm.BackendCapacity.Slots[0].NumRunning = 8
	warm.mu.Unlock()
	for i := 0; i < 8; i++ {
		makeWarmPoolColdProvider(t, reg, fmt.Sprintf("cold-%d", i), model, 20, 64, 8)
	}

	cfg := testWarmPoolConfig()
	cfg.DecodeFloorTPS = 15
	cfg.BurstBuffer = 0
	cfg.MaxLoadsPerTick = 2
	cfg.MaxLoadsPerTickCeiling = 16
	cfg.RampGapFraction = 1.0
	cfg.MaxGlobalPendingLoads = 20
	reg.ConfigureWarmPool(cfg)
	sent := captureWarmPoolLoads(reg)
	reg.RecordWarmPoolCapacityReject(model)

	snaps := reg.warmPool.Tick(time.Now())
	if len(snaps) == 0 {
		t.Fatal("no warm-pool snapshot produced")
	}
	s := snaps[0]
	if s.QualityConcurrency != 1 {
		t.Fatalf("QualityConcurrency = %d, want 1", s.QualityConcurrency)
	}
	if s.RunningRequests != 8 {
		t.Fatalf("RunningRequests = %d, want 8", s.RunningRequests)
	}
	if s.TargetWarm != 8 {
		t.Fatalf("TargetWarm = %d, want 8 (L=8 served / qc=1)", s.TargetWarm)
	}
	// Demand-scaled ramp closes the whole gap (target 8 - warm 1 = 7) in one
	// tick, far above the flat MaxLoadsPerTick=2 baseline — bounded by the
	// per-tick ceiling (16) and the eligible cold pool (8).
	if len(*sent) != 7 {
		t.Fatalf("sent loads = %d, want 7 (demand-scaled ramp)", len(*sent))
	}
}

func TestWarmPoolRampBoundedByCeiling(t *testing.T) {
	reg := New(testLogger())
	model := "warm-pool-ramp-ceiling"
	warm := makeSchedulerProvider(t, reg, "warm", model, 20)
	warm.mu.Lock()
	warm.BackendCapacity.Slots[0].NumRunning = 20
	warm.mu.Unlock()
	for i := 0; i < 12; i++ {
		makeWarmPoolColdProvider(t, reg, fmt.Sprintf("cold-%d", i), model, 20, 64, 8)
	}

	cfg := testWarmPoolConfig()
	cfg.DecodeFloorTPS = 15 // qc = 1 -> target tracks the 20 in-flight requests
	cfg.BurstBuffer = 0
	cfg.MaxLoadsPerTick = 2
	cfg.MaxLoadsPerTickCeiling = 5 // hard per-tick maximum
	cfg.RampGapFraction = 1.0
	cfg.MaxGlobalPendingLoads = 50
	reg.ConfigureWarmPool(cfg)
	sent := captureWarmPoolLoads(reg)
	reg.RecordWarmPoolCapacityReject(model)

	snaps := reg.warmPool.Tick(time.Now())
	if len(snaps) == 0 || snaps[0].TargetWarm < 13 {
		t.Fatalf("snapshot = %+v, want target >= 13", snaps)
	}
	// Gap is large (>= 12) but the per-tick ceiling caps the burst at 5.
	if len(*sent) != 5 {
		t.Fatalf("sent loads = %d, want 5 (ceiling-bounded)", len(*sent))
	}
}
