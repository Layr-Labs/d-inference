package registry_test

import (
	"fmt"
	"sort"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/autopilotcontrol"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	production "github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/registry/autopilot"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

// Reserve includes the exclusive registry snapshot/replan. Its uncontended p95
// is an upper bound on that lock hold, not a production tail-latency claim.
// Eight builds and 1,000 heterogeneous-consent providers exercise real gates.
func BenchmarkAutopilotControllerFleet1000(b *testing.B) {
	for _, operation := range []string{"reserve", "tick"} {
		b.Run(operation, func(b *testing.B) {
			cfg := autopilot.DefaultConfig()
			cfg.Enabled, cfg.ObserveOnly = true, false
			reg, controller := newAutopilotFixture(cfg, func(deps *production.Dependencies) {
				deps.AutopilotSender = func(string, protocol.ModelAutopilotMessage) error { return nil }
			})
			reg.SetStore(memory.NewMemory(store.Config{}))
			var catalog []production.CatalogEntry
			var advertised []protocol.ModelInfo
			var selected []string
			for i := range 8 {
				model := fmt.Sprintf("bench-model-%d", i)
				catalog = append(catalog, production.CatalogEntry{ID: model, SizeGB: 8, MinRAMGB: 16})
				advertised = append(advertised, protocol.ModelInfo{ID: model, SizeBytes: 8_000_000_000, ModelType: "chat"})
				selected = append(selected, model)
			}
			reg.SetModelCatalog(catalog)
			warm := testWarmPoolConfig()
			warm.MinWarmByModel = map[string]int{catalog[0].ID: 1}
			reg.ConfigureWarmPool(warm)
			if err := reg.ConfigureAutopilot(cfg); err != nil {
				b.Fatal(err)
			}
			now := time.Now()
			var providers []*production.Provider
			for i := range 1000 {
				msg := testRegisterMessage()
				msg.Models, msg.DecodeTPS, msg.PrefillTPS = advertised, 100, 2000
				p := reg.Register(fmt.Sprintf("bench-%04d", i), nil, msg)
				reg.Heartbeat(p.ID, &protocol.HeartbeatMessage{Status: "idle", BackendCapacity: autopilotControllerCapacity(10, catalog[1].ID)})
				p.Mu().Lock()
				p.Hardware.MemoryGB = 64
				p.TrustLevel, p.RuntimeVerified, p.RuntimeManifestChecked, p.ChallengeVerifiedSIP = production.TrustHardware, true, true, true
				p.LastChallengeVerified = now
				p.SystemMetrics = protocol.SystemMetrics{ThermalState: "nominal", CPUUsage: .1, MemoryPressure: .1}
				reg.samples[p.ID].MarkAccepted(now)
				p.BackendCapacity = autopilotControllerCapacity(10, catalog[1].ID)
				if i%2 == 0 {
					p.ModelAutopilot = autopilotControllerState(catalog[1].ID)
					p.ModelAutopilot.SelectedModels = append([]string(nil), selected...)
					p.ModelAutopilot.SessionID = p.ID
					// Preserve the load-plan workload, not an unrelated idle unload.
					p.ModelAutopilot.ResidentModels[0].IdleSeconds = 60
					reg.states[p.ID].AcceptControl(p.ModelAutopilot, protocol.ModelAutopilotControl{Revision: p.ModelAutopilot.Revision, ExpiresAtMS: now.Add(time.Hour).UnixMilli()})
				}
				p.Mu().Unlock()
				providers = append(providers, p)
			}
			c := *controller
			a := autopilotcontrol.Plan(c.Fleet(now), cfg, now)
			if a == nil {
				b.Fatal("benchmark fixture did not produce a load plan")
			}
			elapsed := make([]time.Duration, 0, min(b.N, 10000))
			b.ResetTimer()
			for i := 0; i < b.N; i++ {
				start := time.Now()
				if operation == "reserve" {
					if _, ok := c.Reserve(*a, now); !ok {
						b.Fatal("reserve failed")
					}
				} else if s := c.Tick(now); s.Issued != 1 {
					b.Fatalf("tick issued=%d", s.Issued)
				}
				duration := time.Since(start)
				if len(elapsed) < cap(elapsed) {
					elapsed = append(elapsed, duration)
				}
				b.StopTimer()
				for _, p := range providers {
					p.Mu().Lock()
					if delivery, ok := reg.states[p.ID].PrepareDelivery(); ok {
						reg.states[p.ID].RollbackDelivery(delivery)
					}
					p.Mu().Unlock()
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
