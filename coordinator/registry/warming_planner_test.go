package registry

import (
	"context"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// newTestWarmingPlanner builds a registry + planner pair for unit tests.
// The planner is not started; callers invoke planLoads or targetWarmCount directly.
func newTestWarmingPlanner(t *testing.T, cfg WarmingConfig) (*Registry, *WarmingPlanner, *DemandForecaster) {
	t.Helper()
	r := New(testLogger())
	// Lower the trust floor so test providers do not need live attestation state.
	r.MinTrustLevel = TrustNone
	f := NewDemandForecaster(nil, cfg)
	p := NewWarmingPlanner(cfg, f, r, testLogger())
	return r, p, f
}

// newTestProvider returns a minimally routable provider advertising model.
func newTestProvider(id, model string, memGB int) *Provider {
	return &Provider{
		ID:      id,
		Backend: BackendMLXSwift,
		Hardware: protocol.Hardware{
			ChipFamily: "M3",
			MemoryGB:   memGB,
		},
		Models: []protocol.ModelInfo{
			{ID: model},
		},
		TrustLevel:              TrustHardware,
		Status:                  StatusOnline,
		PublicKey:               "fX6XYH7p2hmM3ogeXaAsY+p8M6UKD1df/LJUN9Nj9Nw=",
		EncryptedResponseChunks: true,
		RuntimeVerified:         true,
		RuntimeManifestChecked:  true,
		ChallengeVerifiedSIP:    true,
		LastChallengeVerified:   time.Now(),
		PrivacyCapabilities: &protocol.PrivacyCapabilities{
			TextBackendInprocess: true,
			TextProxyDisabled:    true,
			AntiDebugEnabled:     true,
			CoreDumpsDisabled:    true,
			EnvScrubbed:          true,
		},
		pendingReqs: make(map[string]*PendingRequest),
	}
}

func TestTargetWarmCount(t *testing.T) {
	_, p, _ := newTestWarmingPlanner(t, DefaultWarmingConfig())

	cases := []struct {
		name      string
		recentRPS float64
		queuedRPS float64
		want      int
	}{
		{"no demand", 0, 0, 0},
		{"recent demand only", 5, 0, 2}, // ceil(5 / (6*0.7))
		{"queued demand only", 0, 3, 1}, // ceil(3 / 4.2) = 1
		{"combined demand", 2, 3, 2},    // ceil(5 / 4.2) = 2
		{"single request worth", 1, 0, 1},
		{"large spike capped at 8", 100, 0, 8},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := p.targetWarmCount(DemandForecast{
				RecentRPS: tc.recentRPS,
				QueuedRPS: tc.queuedRPS,
			})
			if got != tc.want {
				t.Fatalf("targetWarmCount(...) = %d, want %d", got, tc.want)
			}
		})
	}
}

func TestPlanLoadsSelectsIdleProvider(t *testing.T) {
	model := "model-a"
	cfg := DefaultWarmingConfig()
	r, planner, f := newTestWarmingPlanner(t, cfg)

	busy := newTestProvider("busy", model, 64)
	idle := newTestProvider("idle", model, 64)

	// busy has one in-flight request; idle has none.
	busy.AddPending(&PendingRequest{RequestID: "r1", Model: model})

	r.mu.Lock()
	r.providers["busy"] = busy
	r.providers["idle"] = idle
	r.mu.Unlock()

	f.RecordQueue(model, 3) // queuedRPS = 1.0, target = 1

	actions := planner.planLoads(context.Background(), []string{model}, time.Now())
	if len(actions) != 1 {
		t.Fatalf("expected 1 action, got %d", len(actions))
	}
	if actions[0].providerID != "idle" {
		t.Fatalf("expected idle provider, got %s", actions[0].providerID)
	}
}

func TestPlanLoadsExcludesAlreadyWarmProvider(t *testing.T) {
	model := "model-a"
	cfg := DefaultWarmingConfig()
	r, planner, f := newTestWarmingPlanner(t, cfg)

	warm := newTestProvider("warm", model, 64)
	warm.WarmModels = []string{model}

	cold := newTestProvider("cold", model, 64)

	r.mu.Lock()
	r.providers["warm"] = warm
	r.providers["cold"] = cold
	r.mu.Unlock()

	// Demand is low enough that the already-warm provider satisfies the target.
	f.RecordQueue(model, 3)

	actions := planner.planLoads(context.Background(), []string{model}, time.Now())
	if len(actions) != 0 {
		t.Fatalf("expected no actions when target already warm, got %d", len(actions))
	}

	// Demand is high enough to require a second warm provider.
	f.RecordQueue(model, 13) // queuedRPS = 4.33, target = 2
	actions = planner.planLoads(context.Background(), []string{model}, time.Now())
	if len(actions) != 1 || actions[0].providerID != "cold" {
		t.Fatalf("expected cold provider action, got %v", actions)
	}
}

func TestPlanLoadsRespectsMaxLoadsPerModelPerTick(t *testing.T) {
	model := "model-a"
	cfg := DefaultWarmingConfig()
	cfg.MaxLoadsPerModelPerTick = 2
	r, planner, f := newTestWarmingPlanner(t, cfg)

	for i := 0; i < 5; i++ {
		p := newTestProvider("p-"+string(rune('a'+i)), model, 64)
		r.mu.Lock()
		r.providers[p.ID] = p
		r.mu.Unlock()
	}

	// Large queue makes target well above the per-tick cap.
	f.RecordQueue(model, 30) // queuedRPS = 10.0, target = 8 (capped)

	actions := planner.planLoads(context.Background(), []string{model}, time.Now())
	if len(actions) != cfg.MaxLoadsPerModelPerTick {
		t.Fatalf("expected %d actions, got %d", cfg.MaxLoadsPerModelPerTick, len(actions))
	}
}

func TestPlanLoadsAntiThrashingPendingLoad(t *testing.T) {
	model := "model-a"
	cfg := DefaultWarmingConfig()
	r, planner, f := newTestWarmingPlanner(t, cfg)

	busy := newTestProvider("busy", model, 64)
	idle := newTestProvider("idle", model, 64)

	r.mu.Lock()
	r.providers["busy"] = busy
	r.providers["idle"] = idle
	// busy already has a pending model load for a different model.
	r.pendingModelLoads["busy:other-model"] = time.Now().Add(pendingModelLoadTTL)
	r.mu.Unlock()

	f.RecordQueue(model, 9) // queuedRPS = 3.0, target = 2

	actions := planner.planLoads(context.Background(), []string{model}, time.Now())
	if len(actions) != 1 || actions[0].providerID != "idle" {
		t.Fatalf("expected only idle provider, got %v", actions)
	}
}

func TestPlanLoadsAntiThrashingDispatchCooldown(t *testing.T) {
	model := "model-a"
	cfg := DefaultWarmingConfig()
	r, planner, f := newTestWarmingPlanner(t, cfg)

	cooled := newTestProvider("cooled", model, 64)
	idle := newTestProvider("idle", model, 64)

	r.mu.Lock()
	r.providers["cooled"] = cooled
	r.providers["idle"] = idle
	r.dispatchLoadCooldowns["cooled:"+model] = time.Now().Add(dispatchLoadCooldownTTL)
	r.mu.Unlock()

	f.RecordQueue(model, 9)

	actions := planner.planLoads(context.Background(), []string{model}, time.Now())
	if len(actions) != 1 || actions[0].providerID != "idle" {
		t.Fatalf("expected only idle provider, got %v", actions)
	}
}

func TestPlanLoadsThermalExclusion(t *testing.T) {
	model := "model-a"
	cfg := DefaultWarmingConfig()
	r, planner, f := newTestWarmingPlanner(t, cfg)

	hot := newTestProvider("hot", model, 64)
	hot.SystemMetrics.ThermalState = "critical"
	hot.thermalHistory = []string{"critical", "critical"}

	cool := newTestProvider("cool", model, 64)
	cool.SystemMetrics.ThermalState = "nominal"

	if !hot.thermallyRejectedLocked() {
		t.Fatal("expected hot provider to be thermally rejected")
	}

	r.mu.Lock()
	r.providers["hot"] = hot
	r.providers["cool"] = cool
	r.mu.Unlock()

	f.RecordQueue(model, 3)

	actions := planner.planLoads(context.Background(), []string{model}, time.Now())
	if len(actions) != 1 || actions[0].providerID != "cool" {
		t.Fatalf("expected cool provider, got %v", actions)
	}
}

func TestPlanLoadsNoEligibleProvider(t *testing.T) {
	model := "model-a"
	cfg := DefaultWarmingConfig()
	r, planner, f := newTestWarmingPlanner(t, cfg)

	// Provider exists but does not advertise the requested model.
	p := newTestProvider("p", "model-b", 64)
	r.mu.Lock()
	r.providers["p"] = p
	r.mu.Unlock()

	f.RecordQueue(model, 9)

	actions := planner.planLoads(context.Background(), []string{model}, time.Now())
	if len(actions) != 0 {
		t.Fatalf("expected no actions when no eligible provider, got %d", len(actions))
	}
}
