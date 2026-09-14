package registry

// DefaultMaxConcurrent is the fallback concurrency limit for providers
// that don't report backend capacity. Providers that report BackendCapacity
// in heartbeats get a dynamic limit based on their total memory.
const DefaultMaxConcurrent = 4

// MaxConcurrency returns the dynamic max concurrent request limit.
// Uses hardware-based estimation when backend capacity is reported.
// Falls back to DefaultMaxConcurrent for providers without capacity reporting.
func (p *Provider) MaxConcurrency() int {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.maxConcurrency()
}

// MaxConcurrencyForModel returns the concurrency limit for a specific model.
// A positive provider-reported slot cap wins; zero/missing preserves the
// legacy provider-level fallback.
func (p *Provider) MaxConcurrencyForModel(model string) int {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.maxConcurrencyForModelLocked(model)
}

// ReportedTokenBudgetMaxForModel returns the provider's most recently reported
// live token budget (ActiveTokenBudgetMax) for the given model, or 0 when the
// provider has reported no per-model token budget. The provider derives this
// value from live memory headroom (see BatchScheduler+Telemetry.swift
// tokenBudgetMax = activeTokenBudgetUsed + headroom/kvBytesPerToken, floored at
// 1024), so it SHRINKS under memory pressure and can fall below the model context
// window. The dispatch path (classifyRejection) uses it to tell a fleet-wide
// context overflow (budget >= model context ⇒ the provider's admission cap
// min(context,budget) was the context, so every provider rejects identically)
// apart from THIS node's shrunk KV budget (budget < context ⇒ a healthier
// provider may still serve), which the bare "batch token budget" wire string
// alone cannot distinguish.
func (p *Provider) ReportedTokenBudgetMaxForModel(model string) int64 {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.BackendCapacity == nil {
		return 0
	}
	for _, slot := range p.BackendCapacity.Slots {
		if slot.Model == model {
			return slot.ActiveTokenBudgetMax
		}
	}
	return 0
}

// maxConcurrency is the lock-free version (caller must hold p.mu).
//
// Tier values were lowered in Phase 2 of the routing-algorithm rework
// (was 4/8/16/24/32). The old caps were derived from "how many
// requests can theoretically fit in GPU memory"; the new caps reflect
// "how many concurrent decodes a single MLX backend can run before
// per-request TPS collapses". Empirically this is much smaller than
// the memory-derived ceiling. Pushing past it makes each request slow
// without increasing fleet throughput.
func (p *Provider) maxConcurrency() int {
	if p.BackendCapacity == nil {
		return DefaultMaxConcurrent
	}

	// Token-budget providers use budget-based admission; the concurrency
	// cap is just a safety valve.
	for _, slot := range p.BackendCapacity.Slots {
		if slot.ActiveTokenBudgetMax > 0 {
			return 24
		}
	}

	// Hardware-based cap using total memory reported by the provider.
	memGB := p.BackendCapacity.TotalMemoryGB
	if memGB <= 0 {
		memGB = float64(p.Hardware.MemoryGB)
	}
	var cap int
	switch {
	case memGB <= 24:
		cap = 2
	case memGB <= 48:
		cap = 4
	case memGB <= 96:
		cap = 6
	case memGB <= 128:
		cap = 8
	default:
		cap = 12
	}
	return cap
}

// maxConcurrencyForModelLocked is the lock-free model-aware concurrency cap.
// Caller must hold p.mu.
func (p *Provider) maxConcurrencyForModelLocked(model string) int {
	if p.BackendCapacity != nil {
		for _, slot := range p.BackendCapacity.Slots {
			if slot.Model == model && slot.MaxConcurrency > 0 {
				return slot.MaxConcurrency
			}
		}
	}
	return p.maxConcurrency()
}

func (p *Provider) pendingCountForModelLocked(model string) int {
	count := 0
	for _, pr := range p.pendingReqs {
		if pr.Model == model {
			count++
		}
	}
	return count
}

func (p *Provider) hasReportedMaxConcurrencyForModelLocked(model string) bool {
	if p.BackendCapacity == nil {
		return false
	}
	for _, slot := range p.BackendCapacity.Slots {
		if slot.Model == model && slot.MaxConcurrency > 0 {
			return true
		}
	}
	return false
}

func (p *Provider) pendingLoadForModelLocked(model string) int {
	if !p.hasReportedMaxConcurrencyForModelLocked(model) {
		return p.pendingCount()
	}

	load := p.pendingCountForModelLocked(model)
	if p.BackendCapacity != nil {
		for _, slot := range p.BackendCapacity.Slots {
			if slot.Model != model {
				continue
			}
			backendLoad := slot.NumRunning + slot.NumWaiting
			if backendLoad > load {
				load = backendLoad
			}
			break
		}
	}
	return load
}
