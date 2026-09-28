package registry

import (
	"testing"
	"time"
)

func TestWarmPoolInactiveBudgetsPreserveQueuedColdLoads(t *testing.T) {
	for _, tc := range []struct {
		name      string
		configure func(*WarmPoolConfig)
	}{
		{"zero_per_tick", func(c *WarmPoolConfig) { c.MaxLoadsPerTick = 0 }},
		{"zero_per_tick_with_ramp_ceiling", func(c *WarmPoolConfig) {
			c.MaxLoadsPerTick, c.MaxLoadsPerTickCeiling = 0, 16
		}},
		{"zero_global", func(c *WarmPoolConfig) { c.MaxGlobalPendingLoads = 0 }},
		{"negative_per_tick", func(c *WarmPoolConfig) { c.MaxLoadsPerTick = -1 }},
		{"negative_global", func(c *WarmPoolConfig) { c.MaxGlobalPendingLoads = -1 }},
		{"disabled", func(c *WarmPoolConfig) { c.Enabled = false }},
		{"observe_only", func(c *WarmPoolConfig) { c.ObserveOnly = true }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			r := New(testLogger())
			const model = "queued-cold-model"
			p := makeWarmPoolColdProvider(t, r, "cold", model, 80, 64, 8)
			cfg := testWarmPoolConfig()
			cfg.QueueAgeThreshold = 0
			tc.configure(&cfg)
			r.ConfigureWarmPool(cfg)
			sent := captureWarmPoolLoads(r)
			if err := r.Queue().Enqueue(swapTestQueued("queued", model)); err != nil {
				t.Fatal(err)
			}
			r.RecordWarmPoolQueueEnqueued(model, 1, 0)

			// Periodic planning remains diagnostic; both hot-path entry points
			// agree it cannot take ownership from the legacy cold-load path.
			snaps := r.warmPool.tick(time.Now())
			if len(snaps) != 1 || !snaps[0].ObserveOnly || len(*sent) != 0 {
				t.Fatalf("inactive controller issued loads: snapshots=%+v sent=%+v", snaps, *sent)
			}
			if r.RequestWarmPoolTrigger() || r.TriggerWarmPool() != nil {
				t.Fatal("inactive controller accepted an active planning trigger")
			}
			r.TriggerModelSwaps()
			if len(*sent) != 1 || (*sent)[0].providerID != p.ID || (*sent)[0].modelID != model {
				t.Fatalf("queued cold model stranded: sent=%+v", *sent)
			}
			if len(r.warmPool.triggerC) != 0 {
				t.Fatal("legacy fallback also scheduled active controller")
			}
		})
	}
}

func TestWarmPoolPositiveBudgetRemainsSolePlanner(t *testing.T) {
	for _, saturated := range []bool{false, true} {
		name := "available"
		if saturated {
			name = "temporarily_exhausted"
		}
		t.Run(name, func(t *testing.T) {
			r := New(testLogger())
			const model = "queued-cold-model"
			p := makeWarmPoolColdProvider(t, r, "cold", model, 80, 64, 8)
			cfg := testWarmPoolConfig()
			cfg.QueueAgeThreshold = 0
			cfg.MaxLoadsPerTick, cfg.MaxLoadsPerTickCeiling, cfg.MaxGlobalPendingLoads = 1, 0, 1
			r.ConfigureWarmPool(cfg)
			sent := captureWarmPoolLoads(r)
			if err := r.Queue().Enqueue(swapTestQueued("queued", model)); err != nil {
				t.Fatal(err)
			}
			r.RecordWarmPoolQueueEnqueued(model, 1, 0)
			key := modelLoadKey{ProviderID: "other-provider", ModelID: "other-model"}
			if saturated {
				r.pendingModelLoads[key] = time.Now().Add(time.Minute)
			}
			r.TriggerModelSwaps()
			r.TriggerModelSwaps()
			if len(*sent) != 0 || len(r.warmPool.triggerC) != 1 {
				t.Fatalf("legacy planner bypassed active owner: sent=%+v triggers=%d", *sent, len(r.warmPool.triggerC))
			}
			if saturated {
				r.warmPool.tick(time.Now())
				if len(*sent) != 0 {
					t.Fatal("controller exceeded its positive global budget")
				}
				delete(r.pendingModelLoads, key)
			}
			r.warmPool.tick(time.Now())
			if len(*sent) != 1 || (*sent)[0].providerID != p.ID || (*sent)[0].modelID != model {
				t.Fatalf("active controller failed to load queued cold model: sent=%+v", *sent)
			}
			r.TriggerModelSwaps()
			r.warmPool.tick(time.Now())
			if len(*sent) != 1 {
				t.Fatal("two planners duplicated the model load")
			}
		})
	}
}
