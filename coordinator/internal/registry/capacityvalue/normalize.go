package capacityvalue

import (
	"log/slog"
	"math"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

// Sanity caps on provider-reported stats. A malicious (or broken) provider
// could otherwise report absurd values to monopolize routing. These caps are
// ~3-4x current hardware ceilings (M2 Ultra is ~800 GB/s, MLX decode is ~120
// tok/s, max Mac Studio RAM is 512 GB) so legitimate future hardware isn't
// clamped unnecessarily.
const (
	MaxDecodeTPS                    = 500.0
	MaxPrefillTPS                   = 20000.0
	MaxMemoryBandwidthGBs           = 2000.0
	MaxMemoryGB                     = 1024
	MaxMemoryGBFloat                = 1024.0
	MaxReportedMaxConcurrency       = 24
	MaxTokensPotential              = 1_000_000
	MaxTokenBudgetCap         int64 = 10_000_000_000 // 10 billion — generous safety valve for total token budget capacity
	MaxModelLoadTimeMS        int64 = 3_600_000      // 1 hour — generous ceiling for a cold-start model load; larger is implausible/garbage
)

// ClampNonNeg returns v clamped into [0, max]; NaN/negative become 0.
// The bool is true if the value was out of range.
func ClampNonNeg(v, max float64) (float64, bool) {
	if math.IsNaN(v) || v < 0 {
		return 0, true
	}
	if v > max {
		return max, true
	}
	return v, false
}

// ClampBackendCapacity applies sanity caps to provider-reported backend
// capacity fields that feed the routing scorer. A provider reporting
// TotalMemoryGB=1e9 would make gpuUtil ~= 0 and dodge health penalties, so
// we cap it at MaxMemoryGBFloat. Same for MaxTokensPotential which directly
// controls backlog cost. NaN/negative become 0.
func ClampBackendCapacity(logger *slog.Logger, providerID string, bc *protocol.BackendCapacity) {
	if bc == nil {
		return
	}
	if v, changed := ClampNonNeg(bc.TotalMemoryGB, MaxMemoryGBFloat); changed {
		logger.Warn("provider total_memory_gb out of range, clamping",
			"provider_id", providerID, "reported", bc.TotalMemoryGB, "clamped", v)
		bc.TotalMemoryGB = v
	}
	if v, changed := ClampNonNeg(bc.GPUMemoryActiveGB, MaxMemoryGBFloat); changed {
		logger.Warn("provider gpu_memory_active_gb out of range, clamping",
			"provider_id", providerID, "reported", bc.GPUMemoryActiveGB, "clamped", v)
		bc.GPUMemoryActiveGB = v
	}
	if v, changed := ClampNonNeg(bc.GPUMemoryPeakGB, MaxMemoryGBFloat); changed {
		bc.GPUMemoryPeakGB = v
	}
	if v, changed := ClampNonNeg(bc.GPUMemoryCacheGB, MaxMemoryGBFloat); changed {
		bc.GPUMemoryCacheGB = v
	}
	// free_for_load_gb: an out-of-range value (NaN/Inf/negative or absurdly high)
	// is treated as NOT reported (nil) so the cold-load gate falls back to the
	// total-memory heuristic, rather than trusting a garbage value that would
	// over- or under-admit. A legitimate 0 ("can't load anything now") is kept.
	if bc.FreeForLoadGB != nil {
		v := *bc.FreeForLoadGB
		if math.IsNaN(v) || math.IsInf(v, 0) || v < 0 || v > MaxMemoryGBFloat {
			logger.Warn("provider free_for_load_gb out of range; ignoring (fall back to heuristic)",
				"provider_id", providerID, "reported", v)
			bc.FreeForLoadGB = nil
		}
	}
	// Owner-facing load diagnostics must remain optional for older providers.
	// Drop malformed samples rather than emitting invalid JSON or a false
	// "fits" verdict in /v1/me/providers.
	if bc.LoadUsableGB != nil && !validLoadDiagnosticGB(*bc.LoadUsableGB) {
		bc.LoadUsableGB = nil
	}
	if bc.LoadHeadroomGB != nil && !validLoadDiagnosticGB(*bc.LoadHeadroomGB) {
		bc.LoadHeadroomGB = nil
	}
	if m := bc.PrefixCacheMaintenance; m != nil {
		m.TTLExpiredTotal = min(m.TTLExpiredTotal, MaxCapacitySampleValue)
		m.BudgetEvictedTotal = min(m.BudgetEvictedTotal, MaxCapacitySampleValue)
		m.TempRemovedTotal = min(m.TempRemovedTotal, MaxCapacitySampleValue)
	}
	for i := range bc.Slots {
		s := &bc.Slots[i]
		ClampPerformanceMeasurements(s.PerformanceMeasurements)
		s.PrefixCache = ClampPrefixCacheTelemetry(s.PrefixCache)
		s.PagedStorage = ClampPagedStorageTelemetry(s.PagedStorage)
		if s.MaxTokensPotential < 0 || s.MaxTokensPotential > MaxTokensPotential {
			logger.Warn("provider slot max_tokens_potential out of range, clamping",
				"provider_id", providerID, "model", s.Model, "reported", s.MaxTokensPotential)
			if s.MaxTokensPotential < 0 {
				s.MaxTokensPotential = 0
			} else {
				s.MaxTokensPotential = MaxTokensPotential
			}
		}
		if s.NumRunning < 0 {
			s.NumRunning = 0
		}
		if s.NumWaiting < 0 {
			s.NumWaiting = 0
		}
		if s.MaxConcurrency < 0 || s.MaxConcurrency > MaxReportedMaxConcurrency {
			logger.Warn("provider slot max_concurrency out of range, clamping",
				"provider_id", providerID, "model", s.Model, "reported", s.MaxConcurrency)
			if s.MaxConcurrency < 0 {
				s.MaxConcurrency = 0
			} else {
				s.MaxConcurrency = MaxReportedMaxConcurrency
			}
		}
		if v, changed := ClampNonNeg(s.ObservedDecodeTPS, MaxDecodeTPS); changed {
			logger.Warn("provider slot observed_decode_tps out of range, clamping",
				"provider_id", providerID, "model", s.Model, "reported", s.ObservedDecodeTPS, "clamped", v)
			s.ObservedDecodeTPS = v
		}
		// observed_prefill_tps: an out-of-range value (NaN/negative, or absurdly
		// high — a known provider-side overflow when the admitted→first-token
		// window collapses on a prefix-cache hit) is treated as NO measurement (0)
		// rather than clamped to the ceiling. Clamping garbage UP to maxPrefillTPS
		// would make the TTFT estimate over-optimistic (prefill looks instant) and
		// the hard gate over-accept; zeroing it makes resolvePrefillTPS fall back to
		// the conservative decode×ratio estimate until the provider reports a sane
		// value (provider fix: only sample cold prefills).
		if math.IsNaN(s.ObservedPrefillTPS) || s.ObservedPrefillTPS < 0 || s.ObservedPrefillTPS > MaxPrefillTPS {
			logger.Warn("provider slot observed_prefill_tps out of range; ignoring (fall back to estimate)",
				"provider_id", providerID, "model", s.Model, "reported", s.ObservedPrefillTPS)
			s.ObservedPrefillTPS = 0
		}
		if s.ModelLoadTimeMS < 0 || s.ModelLoadTimeMS > MaxModelLoadTimeMS {
			logger.Warn("provider slot model_load_time_ms out of range, clamping",
				"provider_id", providerID, "model", s.Model, "reported", s.ModelLoadTimeMS)
			if s.ModelLoadTimeMS < 0 {
				s.ModelLoadTimeMS = 0
			} else {
				s.ModelLoadTimeMS = MaxModelLoadTimeMS
			}
		}
		if s.ActiveTokenBudgetUsed < 0 || s.ActiveTokenBudgetUsed > MaxTokenBudgetCap {
			if s.ActiveTokenBudgetUsed < 0 {
				s.ActiveTokenBudgetUsed = 0
			} else {
				s.ActiveTokenBudgetUsed = MaxTokenBudgetCap
			}
		}
		if s.ActiveTokenBudgetMax < 0 || s.ActiveTokenBudgetMax > MaxTokenBudgetCap {
			if s.ActiveTokenBudgetMax < 0 {
				s.ActiveTokenBudgetMax = 0
			} else {
				s.ActiveTokenBudgetMax = MaxTokenBudgetCap
			}
		}
		if s.QueuedTokenBudget < 0 || s.QueuedTokenBudget > MaxTokenBudgetCap {
			if s.QueuedTokenBudget < 0 {
				s.QueuedTokenBudget = 0
			} else {
				s.QueuedTokenBudget = MaxTokenBudgetCap
			}
		}
		if t := s.Telemetry; t != nil {
			// Counts remain bounded for diagnostics and routing forecasts.
			// t is the registry-owned clone made by canonicalHeartbeatModelState.
			clampTelemetryCount(t.QueuedPrefillTokens)
			clampTelemetryCount(t.PartialPrefillRows)
			clampTelemetryCount(t.PrefillTokensTotal)
			clampTelemetryCount(t.PrefillRequestsTotal)
			clampTelemetryCount(t.GeneratedTokensTotal)
			clampTelemetryCount(t.GenerationRequestsTotal)
			clampTelemetryCount(t.PumpTasks)
			clampTelemetryCount(t.MTPRoundsTotal)
			clampTelemetryCount(t.MTPProposedTotal)
			clampTelemetryCount(t.MTPAcceptedTotal)
			clampTelemetryCount(t.DecodeRowsTotal)
			clampTelemetryInt64(t.KVBytesInUse, MaxTelemetryBytes)
			clampTelemetryInt64(t.KVBytesCapacity, MaxTelemetryBytes)
			clampTelemetryInt64(t.EvalInFlightMS, MaxTelemetryMS)
			// Cumulative ns of engine step wall time: a count cap would wrap
			// after ~17 min of stepping, so it gets the wide ns bound.
			clampTelemetryInt64(t.StepWallNSTotal, MaxTelemetryNSTotal)
			if p := t.IsolatedPrefillTPS; p != nil {
				if math.IsNaN(*p) || math.IsInf(*p, 0) || *p < 0 || *p > MaxPrefillTPS {
					logger.Warn("provider isolated_prefill_tps out of range; ignoring",
						"provider_id", providerID, "model", s.Model, "reported", *p)
					t.IsolatedPrefillTPS = nil
				}
			}
		}
	}
	if t := bc.Telemetry; t != nil {
		clampTelemetryCount(t.MLXNumResources)
		clampTelemetryCount(t.InAdmission)
		clampTelemetryCount(t.InflightTasks)
		t.MemoryPressureLevel = t.MemoryPressureLevel.Fold()
		t.ProcessMemory = ValidProcessMemoryTelemetry(t.ProcessMemory)
	}
}

func validLoadDiagnosticGB(v float64) bool {
	return !math.IsNaN(v) && !math.IsInf(v, 0) && v >= 0 && v <= MaxMemoryGBFloat
}

// System-profiler heartbeat telemetry bounds (CONTRACT-WIRE.md §2). Pointer
// numerics are clamped in place into [0, max]; nil (absent) is left alone so
// presence semantics survive.
const (
	MaxTelemetryCount   int64 = 1_000_000_000_000 // 1e12
	MaxTelemetryBytes   int64 = 1 << 48
	MaxTelemetryMS      int64 = 3_600_000                 // 1 h
	MaxTelemetryNSTotal int64 = 1_000_000_000_000_000_000 // 1e18 ≈ 31 y of cumulative ns
)

func clampTelemetryInt64(p *int64, limit int64) {
	if p == nil {
		return
	}
	if *p < 0 {
		*p = 0
	} else if *p > limit {
		*p = limit
	}
}

func clampTelemetryCount(p *int64) { clampTelemetryInt64(p, MaxTelemetryCount) }
