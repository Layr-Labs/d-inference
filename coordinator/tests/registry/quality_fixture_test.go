package registry_test

import (
	"fmt"
	"log/slog"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/env"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/quality"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/warmplan"
	production "github.com/eigeninference/d-inference/coordinator/registry"
)

const (
	effectiveTPSLoadFactor         = warmplan.DecodeLoadFactor
	defaultQualityCapOvercommit    = quality.DefaultOvercommit
	qualityCapOvercommitByModelEnv = env.EnvPrefix + "_QUALITY_CONCURRENCY_OVERCOMMIT_BY_MODEL"
	qualityCapPerModelTPSEnv       = env.EnvPrefix + "_QUALITY_CAP_PER_MODEL_TPS"
	qualityCapSoloMinSamplesEnv    = env.EnvPrefix + "_QUALITY_CAP_SOLO_MIN_SAMPLES"
	modelSoloTPSSeedEnv            = env.EnvPrefix + "_MODEL_SOLO_TPS_SEED"
	soloSeedClassSep               = quality.SeedClassSeparator
	// CBv2 paged B=1 per-request decode, not the aggregate Gate G0a rate.
	// libs/mlx-swift-lm/benchmarks/reports/gemma4-26b-qat4bit-paged-gate-2026-07-09.md
	measuredGemmaSoloTPSPaged = 99.5
)

type qualityFixture struct {
	*production.Registry
	throughput *production.TPSRegistry
	policy     *quality.Policy
	fleet      func(time.Time) map[string]warmplan.Fleet
	runtime    *warmplan.Controller[production.ModelLoadAction]
	t          *testing.T
}

func newQualityRegistry(logger *slog.Logger, configure ...func(*production.Dependencies)) *qualityFixture {
	f := &qualityFixture{throughput: production.NewTPSRegistry(), policy: &quality.Policy{}}
	deps := production.Dependencies{
		Throughput: f.throughput, QualityPolicy: f.policy,
		WarmPlanning: func(input warmplan.Dependencies[production.ModelLoadAction]) *warmplan.Controller[production.ModelLoadAction] {
			f.fleet = input.Fleet
			f.runtime = warmplan.NewController(input)
			return f.runtime
		},
	}
	for _, apply := range configure {
		apply(&deps)
	}
	f.Registry = production.NewWithDependencies(logger, deps)
	return f
}

func qualityProvider(t *testing.T, f *qualityFixture, id, model string, decodeTPS float64, advertised ...string) *production.Provider {
	t.Helper()
	f.t = t
	p := makeSchedulerProvider(t, f.Registry, id, model, decodeTPS, advertised...)
	setSchedulerProviderSerial(p, id)
	return p
}

func resolveSolo(f *qualityFixture, p *production.Provider, model string) quality.Rate {
	p.Mu().Lock()
	hardware, benchmark := p.Hardware, p.DecodeTPS
	p.Mu().Unlock()
	class := quality.ChipClass(hardware)
	var evidence quality.SoloEvidence
	evidence.ClassTPS, evidence.ClassSamples = f.throughput.SoloMedian(model, class)
	evidence.MinimumTPS, evidence.TotalSamples, evidence.Classes = f.throughput.SoloMedianAllChips(model)
	return f.policy.Resolve(evidence, model, class, quality.DecodeFallback(benchmark, hardware), benchmark > 0 || hardware.MemoryBandwidthGBs > 0)
}

func providerDecodeFallback(p *production.Provider) float64 {
	p.Mu().Lock()
	defer p.Mu().Unlock()
	return quality.DecodeFallback(p.DecodeTPS, p.Hardware)
}

// Pending requests exercise the real load counter even when a legacy slot has
// no reported concurrency gauge. The serial restriction isolates this provider.
func effCapResolved(f *qualityFixture, p *production.Provider, model string) int {
	f.t.Helper()
	base := p.MaxConcurrencyForModel(model)
	p.Mu().Lock()
	reportedSlot := -1
	for i, slot := range p.BackendCapacity.Slots {
		if slot.Model == model && slot.MaxConcurrency > 0 {
			reportedSlot = i
			break
		}
	}
	running := 0
	if reportedSlot >= 0 {
		running = p.BackendCapacity.Slots[reportedSlot].NumRunning
	}
	p.Mu().Unlock()
	ids := make([]string, 0, base)
	defer func() {
		for _, id := range ids {
			p.RemovePending(id)
		}
		if reportedSlot >= 0 {
			p.Mu().Lock()
			p.BackendCapacity.Slots[reportedSlot].NumRunning = running
			p.Mu().Unlock()
		}
	}()
	for batch := 0; batch <= base; batch++ {
		if reportedSlot >= 0 {
			p.Mu().Lock()
			p.BackendCapacity.Slots[reportedSlot].NumRunning = batch
			p.Mu().Unlock()
		} else if batch > 0 {
			id := fmt.Sprintf("quality-probe-%s-%d", model, batch)
			ids = append(ids, id)
			p.AddPending(&production.PendingRequest{RequestID: id, Model: model})
		}
		if candidates, _, _ := f.QuickCapacityCheck(model, 0, 1, production.RequestTraits{}, p.ID); candidates == 0 {
			if batch == 0 {
				f.t.Fatalf("provider %s rejected before concurrency was exhausted", p.ID)
			}
			return batch
		}
	}
	f.t.Fatalf("provider %s admitted beyond its reported cap %d", p.ID, base)
	return 0
}

func explicitRateCap(f *qualityFixture, p *production.Provider, model string, rate quality.Rate) int {
	base := p.MaxConcurrencyForModel(model)
	p.Mu().Lock()
	benchmark := p.DecodeTPS > 0
	p.Mu().Unlock()
	return f.policy.Cap(model, base, rate, benchmark, f.IsDedicatedModel(model), effectiveTPSLoadFactor, nil)
}

func effCap(f *qualityFixture, p *production.Provider, model string) int {
	p.Mu().Lock()
	fallback := quality.DecodeFallback(p.DecodeTPS, p.Hardware)
	p.Mu().Unlock()
	cap := explicitRateCap(f, p, model, quality.Rate{TPS: fallback})
	if rate := resolveSolo(f, p, model); !rate.PerModel {
		if actual := effCapResolved(f, p, model); actual != cap {
			f.t.Fatalf("production admission cap %d != explicit fallback policy cap %d", actual, cap)
		}
	}
	return cap
}
