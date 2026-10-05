package autopilotcontrol

import (
	"math"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/performance"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/warmplan"
	"github.com/eigeninference/d-inference/coordinator/modelpolicy"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry/autopilot"
)

// FitEvidence contains the qualified rate evidence for one model. The registry
// resolves catalog, attestation and runtime gates before pricing.
type FitEvidence struct {
	Model                      string
	SoloTPS, PrefillTPS        float64
	MaxConcurrency             int
	DecodeFloorTPS, LoadFactor float64
	Profile                    *performance.Profile
	SuccessfulJobs, TotalJobs  int
	Metrics                    protocol.SystemMetrics
	Slots                      []protocol.BackendSlotCapacity
	LoadHistory                []protocol.ModelAutopilotLoadTiming
	WeightHash                 string
	ResponseTime               time.Duration
}

type FitLimits struct {
	WeightsGiB                         float64
	Restricted, Measured, HardwareFits bool
	ColdTokenBudget                    int64
}

// Limits are resolved only after usable service rates and load timing. This
// preserves the registry's late catalog lookup and sample-median cache work.
func ModelFit(e FitEvidence, d autopilot.DemandView, cfg autopilot.Config, resolveLimits func() FitLimits) autopilot.ModelFit {
	prefill := e.PrefillTPS
	qc := min(e.MaxConcurrency, warmplan.QualityConcurrency(e.SoloTPS, e.DecodeFloorTPS, e.LoadFactor, e.MaxConcurrency, 1))
	decode := e.SoloTPS / (1 + e.LoadFactor*float64(qc))
	if profile := e.Profile; profile != nil {
		qc = profile.ConcurrencyForDecodeFloor(e.MaxConcurrency, e.DecodeFloorTPS)
		if point, ok := profile.BatchAt(qc); ok {
			decode = point.AggregateDecodeTPS / float64(qc)
			if point.Width != qc {
				decode = point.DecodeP10TPS
			}
			prefill = point.PrefillTPS
		}
	}
	if e.SoloTPS <= 0 || prefill <= 0 || qc < 1 {
		return autopilot.ModelFit{}
	}
	prompt, output := max(1, d.PromptTokens), max(1, d.OutputTokens)
	if d.Requests == 0 && d.Queued == 0 && d.InFlight == 0 {
		prompt, output = 512, 256
	}
	service := math.Max(.1, float64(prompt)/prefill+float64(output)/decode)
	// Sparse job outcomes retain the existing modest reliability prior.
	reliability := (float64(max(0, e.SuccessfulJobs)) + 9) / (float64(max(0, e.TotalJobs)) + 10)
	reliability = math.Max(.1, math.Min(1, reliability))
	resourceFactor := math.Max(.25, 1-.5*e.Metrics.MemoryPressure-.25*e.Metrics.CPUUsage)
	if e.Metrics.ThermalState == "fair" {
		resourceFactor *= .85
	}
	if e.Metrics.ThermalState == "serious" || e.Metrics.ThermalState == "critical" {
		resourceFactor *= .5
	}
	rate := float64(qc) / service * cfg.TargetUtilization * reliability * resourceFactor
	load := cfg.LoadTimePrior.Seconds()
	for _, slot := range e.Slots {
		if slot.Model == e.Model && slot.ModelLoadTimeMS > 0 {
			load = math.Max(1, float64(slot.ModelLoadTimeMS)/1000)
			break
		}
	}
	for _, timing := range e.LoadHistory {
		age := time.Since(time.UnixMilli(timing.MeasuredAtMS))
		if timing.ModelID == e.Model && e.WeightHash != "" && timing.WeightHash == e.WeightHash && timing.LoadMS > 0 && timing.LoadMS <= 1800000 && age >= 0 && age < 7*24*time.Hour {
			load = math.Max(1, float64(timing.LoadMS)/1000)
		}
	}
	tail := max(prompt, d.TailPromptTokens)
	deadline := modelpolicy.CoordinatorFirstContentDeadline(e.Model, tail, 5*time.Second).Seconds()
	first := float64(tail)/prefill + 1/e.SoloTPS + math.Max(0, e.ResponseTime.Seconds())
	if d.DeadlineKnown {
		deadline = d.DeadlineSeconds
	}
	limits := resolveLimits()
	fit := autopilot.ModelFit{Rate: rate, ServiceSeconds: service, LoadSeconds: load, WeightsGiB: limits.WeightsGiB, Restricted: limits.Restricted, Measured: limits.Measured, MeetsDeadline: (d.DeadlineKnown && deadline <= 0) || first <= deadline*.8}
	if !limits.HardwareFits {
		fit.MeetsDeadline = false
	}
	budget := limits.ColdTokenBudget
	for _, slot := range e.Slots {
		if slot.Model == e.Model && (slot.State == "running" || slot.State == "idle") {
			budget = slot.ActiveTokenBudgetMax
			break
		}
	}
	maxOutput := d.RequestedMaxTokens
	if maxOutput <= 0 {
		maxOutput = 256
	}
	envelope := int64(tail) + int64(maxOutput)
	if (d.Requests > 0 || d.Queued > 0 || d.InFlight > 0) && (budget <= 0 || envelope > budget) {
		fit.MeetsDeadline = false
	}
	return fit
}
