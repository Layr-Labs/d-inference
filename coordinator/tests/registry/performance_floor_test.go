package registry_test

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/performance"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/warmplan"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

func TestQualifiedProfilePreservesConfiguredDecodeFloor(t *testing.T) {
	for _, tc := range []struct {
		name           string
		enabled        bool
		floor          float64
		operator, want int
	}{
		{"release floor", true, 30, 16, 16},
		{"raised floor", true, 40, 16, 8},
		{"stricter floor", true, 45, 16, 4},
		{"operator between passing widths", true, 40, 6, 6},
		{"operator between rejected widths", true, 45, 6, 4},
		{"operator below passing point", true, 45, 3, 3},
		{"floor above solo", true, 100, 16, 1},
		{"floor disabled", false, 100, 16, 16},
		{"zero floor", true, 0, 16, 16},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var fleet func(time.Time) map[string]warmplan.Fleet
			reg, p, profile := reviewedServingProvider(t, func(deps *production.Dependencies) {
				deps.WarmPlanning = func(input warmplan.Dependencies[production.ModelLoadAction]) *warmplan.Controller[production.ModelLoadAction] {
					fleet = input.Fleet
					return warmplan.NewController(input)
				}
			})
			profile.BatchCurve = []performance.BatchPoint{
				{Width: 1, DecodeP10TPS: 90, AggregateDecodeTPS: 100, PrefillTPS: 6000, FirstContentP95MS: 1200},
				{Width: 4, DecodeP10TPS: 50, AggregateDecodeTPS: 250, PrefillTPS: 5000, FirstContentP95MS: 1500},
				{Width: 8, DecodeP10TPS: 40, AggregateDecodeTPS: 450, PrefillTPS: 4500, FirstContentP95MS: 1800},
				{Width: 16, DecodeP10TPS: 35, AggregateDecodeTPS: 700, PrefillTPS: 4000, FirstContentP95MS: 2800},
			}
			p.Mu().Lock()
			p.BackendCapacity.Slots[0].MaxConcurrency = tc.operator
			p.Mu().Unlock()
			reg.SetQualityConcurrencyCap(tc.enabled, 1, tc.floor, 1)
			got := 0
			// Vary only the reported batch: the real capacity admission boundary
			// must reject at the configured quality cap, not just expose a number.
			for batch := 1; batch <= tc.operator; batch++ {
				p.Mu().Lock()
				p.BackendCapacity.Slots[0].NumRunning = batch
				p.BackendCapacity.Slots[0].State = "running"
				p.Mu().Unlock()
				if candidates, _, _ := reg.QuickCapacityCheck("model", 0, 1, production.RequestTraits{}); candidates == 0 {
					got = batch
					break
				}
			}
			if got != tc.want {
				t.Fatalf("admission cap = %d, want %d", got, tc.want)
			}
			p.Mu().Lock()
			p.BackendCapacity.Slots[0].NumRunning = 0
			p.BackendCapacity.Slots[0].State = "idle"
			p.Mu().Unlock()
			warmFloor := tc.floor
			if !tc.enabled {
				warmFloor = 0
			}
			reg.ConfigureWarmPool(warmplan.Config{DecodeFloorTPS: warmFloor})
			snapshot := fleet(time.Now())["model"]
			quality, aggregate, prefill := snapshot.QualityConc, snapshot.AggregateDecodeTPS, snapshot.PrefillTPS
			point, _ := profile.BatchAt(tc.want)
			wantAggregate := point.AggregateDecodeTPS
			if point.Width != tc.want {
				wantAggregate = point.DecodeP10TPS * float64(tc.want)
			}
			if quality != tc.want || aggregate != wantAggregate || prefill != point.PrefillTPS {
				t.Fatalf("warm capacity = %d/%v/%v, want %d/%v/%v", quality, aggregate, prefill, tc.want, wantAggregate, point.PrefillTPS)
			}
		})
	}
}
