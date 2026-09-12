package registry

import (
	"fmt"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"sort"
	"testing"
	"time"
)

// These benchmarks report operation wall time without contention. Reserve's
// expensive snapshot/replan currently runs under the exclusive registry lock,
// so its p95 approximates an upper bound on that write-lock hold (it also
// includes the small pre-lock demand snapshot). This is not a production tail
// latency claim. Eight cached builds and 1,000 heterogeneous-consent providers
// exercise the actual registry gates/rate resolution rather than pure fixtures.
func BenchmarkAutopilotControllerFleet1000(b *testing.B) {
	for _, operation := range []string{"reserve", "tick"} {
		b.Run(operation, func(b *testing.B) {
			reg := New(testLogger())
			var catalog []CatalogEntry
			var advertised []protocol.ModelInfo
			for i := range 8 {
				model := fmt.Sprintf("bench-model-%d", i)
				catalog = append(catalog, CatalogEntry{ID: model, SizeGB: 8, MinRAMGB: 16})
				advertised = append(advertised, protocol.ModelInfo{ID: model, SizeBytes: 8_000_000_000, ModelType: "chat"})
			}
			reg.SetModelCatalog(catalog)
			warm := testWarmPoolConfig()
			warm.MinWarmByModel = map[string]int{catalog[0].ID: 1}
			reg.ConfigureWarmPool(warm)
			cfg := DefaultAutopilotConfig()
			cfg.Enabled, cfg.ObserveOnly = true, false
			if err := reg.ConfigureAutopilot(cfg); err != nil {
				b.Fatal(err)
			}
			reg.autopilotSender = func(string, protocol.ModelAutopilotMessage) error { return nil }
			now := time.Now()
			var providers []*Provider
			for i := range 1000 {
				msg := testRegisterMessage()
				msg.Models, msg.DecodeTPS, msg.PrefillTPS = advertised, 100, 2000
				p := reg.Register(fmt.Sprintf("bench-%04d", i), nil, msg)
				p.mu.Lock()
				p.Hardware.MemoryGB = 64
				p.TrustLevel, p.RuntimeVerified, p.RuntimeManifestChecked, p.ChallengeVerifiedSIP = TrustHardware, true, true, true
				p.LastChallengeVerified = now
				p.SystemMetrics = protocol.SystemMetrics{ThermalState: "nominal", CPUUsage: .1, MemoryPressure: .1}
				p.capacitySeq, p.capacitySamplesAt = 10, now
				p.BackendCapacity = autopilotControllerCapacity(10, catalog[1].ID)
				if i%2 == 0 {
					p.ModelAutopilot = autopilotControllerState(catalog[1].ID)
				}
				p.mu.Unlock()
				providers = append(providers, p)
			}
			c := reg.autopilot
			a := planAutopilotAction(reg.autopilotFleetSnapshot(c, now), cfg, now)
			if a == nil {
				b.Fatal("benchmark fixture did not produce a load plan")
			}
			elapsed := make([]time.Duration, 0, min(b.N, 10000))
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				start := time.Now()
				if operation == "reserve" {
					if _, ok := reg.reserveAutopilotAction(c, *a, now); !ok {
						b.Fatal("reserve failed")
					}
				} else if s := c.tick(now); s.Issued != 1 {
					b.Fatalf("tick issued=%d", s.Issued)
				}
				duration := time.Since(start)
				if len(elapsed) < cap(elapsed) {
					elapsed = append(elapsed, duration)
				}
				b.StopTimer()
				for _, p := range providers {
					p.mu.Lock()
					p.autopilotPending = nil
					p.mu.Unlock()
				}
				b.StartTimer()
			}
			b.StopTimer()
			sort.Slice(elapsed, func(i, j int) bool { return elapsed[i] < elapsed[j] })
			if len(elapsed) > 0 {
				b.ReportMetric(float64(elapsed[min(len(elapsed)-1, len(elapsed)*95/100)].Microseconds())/1000, "p95-ms")
			}
		})
	}
}
