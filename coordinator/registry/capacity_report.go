package registry

import (
	"log/slog"
	"math"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry/routingcost"
)

// Sanity caps on provider-reported stats. A malicious (or broken) provider
// could otherwise report absurd values to monopolize routing. These caps are
// ~3-4x current hardware ceilings (M2 Ultra is ~800 GB/s, MLX decode is ~120
// tok/s, max Mac Studio RAM is 512 GB) so legitimate future hardware isn't
// clamped unnecessarily.
const (
	maxDecodeTPS                    = 500.0
	maxPrefillTPS                   = routingcost.MaxPrefillTPS
	maxMemoryBandwidthGBs           = 2000.0
	maxMemoryGB                     = 1024
	maxMemoryGBFloat                = 1024.0
	maxReportedMaxConcurrency       = 24
	maxTokensPotential              = 1_000_000
	maxTokenBudgetCap         int64 = 10_000_000_000 // 10 billion — generous safety valve for total token budget capacity
	maxModelLoadTimeMS        int64 = 3_600_000      // 1 hour — generous ceiling for a cold-start model load; larger is implausible/garbage
)

// clampNonNeg returns v clamped into [0, max]; NaN/negative become 0.
// The bool is true if the value was out of range.
func clampNonNeg(v, max float64) (float64, bool) {
	if math.IsNaN(v) || v < 0 {
		return 0, true
	}
	if v > max {
		return max, true
	}
	return v, false
}

// clampBackendCapacity applies sanity caps to provider-reported backend
// capacity fields that feed the routing scorer. A provider reporting
// TotalMemoryGB=1e9 would make gpuUtil ~= 0 and dodge health penalties, so
// we cap it at maxMemoryGBFloat. Same for MaxTokensPotential which directly
// controls backlog cost. NaN/negative become 0.
func clampBackendCapacity(logger *slog.Logger, providerID string, bc *protocol.BackendCapacity) {
	if bc == nil {
		return
	}
	if v, changed := clampNonNeg(bc.TotalMemoryGB, maxMemoryGBFloat); changed {
		logger.Warn("provider total_memory_gb out of range, clamping",
			"provider_id", providerID, "reported", bc.TotalMemoryGB, "clamped", v)
		bc.TotalMemoryGB = v
	}
	if v, changed := clampNonNeg(bc.GPUMemoryActiveGB, maxMemoryGBFloat); changed {
		logger.Warn("provider gpu_memory_active_gb out of range, clamping",
			"provider_id", providerID, "reported", bc.GPUMemoryActiveGB, "clamped", v)
		bc.GPUMemoryActiveGB = v
	}
	if v, changed := clampNonNeg(bc.GPUMemoryPeakGB, maxMemoryGBFloat); changed {
		bc.GPUMemoryPeakGB = v
	}
	if v, changed := clampNonNeg(bc.GPUMemoryCacheGB, maxMemoryGBFloat); changed {
		bc.GPUMemoryCacheGB = v
	}
	// free_for_load_gb: an out-of-range value (NaN/Inf/negative or absurdly high)
	// is treated as NOT reported (nil) so the cold-load gate falls back to the
	// total-memory heuristic, rather than trusting a garbage value that would
	// over- or under-admit. A legitimate 0 ("can't load anything now") is kept.
	if bc.FreeForLoadGB != nil {
		v := *bc.FreeForLoadGB
		if math.IsNaN(v) || math.IsInf(v, 0) || v < 0 || v > maxMemoryGBFloat {
			logger.Warn("provider free_for_load_gb out of range; ignoring (fall back to heuristic)",
				"provider_id", providerID, "reported", v)
			bc.FreeForLoadGB = nil
		}
	}
	if m := bc.PrefixCacheMaintenance; m != nil {
		m.TTLExpiredTotal = min(m.TTLExpiredTotal, maxCapacitySampleValue)
		m.BudgetEvictedTotal = min(m.BudgetEvictedTotal, maxCapacitySampleValue)
		m.TempRemovedTotal = min(m.TempRemovedTotal, maxCapacitySampleValue)
	}
	for i := range bc.Slots {
		s := &bc.Slots[i]
		s.PrefixCache = clampPrefixCacheTelemetry(s.PrefixCache)
		s.PagedStorage = clampPagedStorageTelemetry(s.PagedStorage)
		if s.MaxTokensPotential < 0 || s.MaxTokensPotential > maxTokensPotential {
			logger.Warn("provider slot max_tokens_potential out of range, clamping",
				"provider_id", providerID, "model", s.Model, "reported", s.MaxTokensPotential)
			if s.MaxTokensPotential < 0 {
				s.MaxTokensPotential = 0
			} else {
				s.MaxTokensPotential = maxTokensPotential
			}
		}
		if s.NumRunning < 0 {
			s.NumRunning = 0
		}
		if s.NumWaiting < 0 {
			s.NumWaiting = 0
		}
		if s.MaxConcurrency < 0 || s.MaxConcurrency > maxReportedMaxConcurrency {
			logger.Warn("provider slot max_concurrency out of range, clamping",
				"provider_id", providerID, "model", s.Model, "reported", s.MaxConcurrency)
			if s.MaxConcurrency < 0 {
				s.MaxConcurrency = 0
			} else {
				s.MaxConcurrency = maxReportedMaxConcurrency
			}
		}
		if v, changed := clampNonNeg(s.ObservedDecodeTPS, maxDecodeTPS); changed {
			logger.Warn("provider slot observed_decode_tps out of range, clamping",
				"provider_id", providerID, "model", s.Model, "reported", s.ObservedDecodeTPS, "clamped", v)
			s.ObservedDecodeTPS = v
		}
		// observed_prefill_tps: an out-of-range value (NaN/negative, or absurdly
		// high — a known provider-side overflow when the admitted→first-token
		// window collapses on a prefix-cache hit) is treated as NO measurement (0)
		// rather than clamped to the ceiling. Clamping garbage UP to maxPrefillTPS
		// would make the TTFT estimate over-optimistic (prefill looks instant) and
		// the hard gate over-accept; zeroing it makes routingcost.ResolvePrefillTPS fall back to
		// the conservative decode×ratio estimate until the provider reports a sane
		// value (provider fix: only sample cold prefills).
		if math.IsNaN(s.ObservedPrefillTPS) || s.ObservedPrefillTPS < 0 || s.ObservedPrefillTPS > maxPrefillTPS {
			logger.Warn("provider slot observed_prefill_tps out of range; ignoring (fall back to estimate)",
				"provider_id", providerID, "model", s.Model, "reported", s.ObservedPrefillTPS)
			s.ObservedPrefillTPS = 0
		}
		if s.ModelLoadTimeMS < 0 || s.ModelLoadTimeMS > maxModelLoadTimeMS {
			logger.Warn("provider slot model_load_time_ms out of range, clamping",
				"provider_id", providerID, "model", s.Model, "reported", s.ModelLoadTimeMS)
			if s.ModelLoadTimeMS < 0 {
				s.ModelLoadTimeMS = 0
			} else {
				s.ModelLoadTimeMS = maxModelLoadTimeMS
			}
		}
		if s.ActiveTokenBudgetUsed < 0 || s.ActiveTokenBudgetUsed > maxTokenBudgetCap {
			if s.ActiveTokenBudgetUsed < 0 {
				s.ActiveTokenBudgetUsed = 0
			} else {
				s.ActiveTokenBudgetUsed = maxTokenBudgetCap
			}
		}
		if s.ActiveTokenBudgetMax < 0 || s.ActiveTokenBudgetMax > maxTokenBudgetCap {
			if s.ActiveTokenBudgetMax < 0 {
				s.ActiveTokenBudgetMax = 0
			} else {
				s.ActiveTokenBudgetMax = maxTokenBudgetCap
			}
		}
		if s.QueuedTokenBudget < 0 || s.QueuedTokenBudget > maxTokenBudgetCap {
			if s.QueuedTokenBudget < 0 {
				s.QueuedTokenBudget = 0
			} else {
				s.QueuedTokenBudget = maxTokenBudgetCap
			}
		}
		if t := s.Telemetry; t != nil {
			// System-profiler slot telemetry (measurement only). Silent
			// clamps, like the token-budget fields above: nothing routes on
			// these, so a bad value is not worth a log line per heartbeat.
			// t is the registry-owned clone made by canonicalHeartbeatModelState.
			clampTelemetryCount(t.QueuedPrefillTokens)
			clampTelemetryCount(t.PartialPrefillRows)
			clampTelemetryCount(t.PrefillTokensTotal)
			clampTelemetryCount(t.PumpTasks)
			clampTelemetryCount(t.MTPRoundsTotal)
			clampTelemetryCount(t.MTPProposedTotal)
			clampTelemetryCount(t.MTPAcceptedTotal)
			clampTelemetryCount(t.DecodeRowsTotal)
			clampTelemetryInt64(t.KVBytesInUse, maxTelemetryBytes)
			clampTelemetryInt64(t.KVBytesCapacity, maxTelemetryBytes)
			clampTelemetryInt64(t.EvalInFlightMS, maxTelemetryMS)
			// Cumulative ns of engine step wall time: a count cap would wrap
			// after ~17 min of stepping, so it gets the wide ns bound.
			clampTelemetryInt64(t.StepWallNSTotal, maxTelemetryNSTotal)
			if p := t.IsolatedPrefillTPS; p != nil {
				if math.IsNaN(*p) || math.IsInf(*p, 0) {
					t.IsolatedPrefillTPS = nil // garbage reads as "not reported"
				} else if v, changed := clampNonNeg(*p, maxTelemetryTPS); changed {
					*p = v
				}
			}
		}
	}
	if t := bc.Telemetry; t != nil {
		clampTelemetryCount(t.MLXNumResources)
		clampTelemetryCount(t.InAdmission)
		clampTelemetryCount(t.InflightTasks)
		t.MemoryPressureLevel = t.MemoryPressureLevel.Fold()
		t.ProcessMemory = validProcessMemoryTelemetry(t.ProcessMemory)
	}
}

// System-profiler heartbeat telemetry bounds (CONTRACT-WIRE.md §2). Pointer
// numerics are clamped in place into [0, max]; nil (absent) is left alone so
// presence semantics survive.
const (
	maxTelemetryCount   int64   = 1_000_000_000_000 // 1e12
	maxTelemetryBytes   int64   = 1 << 48
	maxTelemetryMS      int64   = 3_600_000                 // 1 h
	maxTelemetryNSTotal int64   = 1_000_000_000_000_000_000 // 1e18 ≈ 31 y of cumulative ns
	maxTelemetryTPS     float64 = 20_000
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

func clampTelemetryCount(p *int64) { clampTelemetryInt64(p, maxTelemetryCount) }
