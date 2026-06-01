package registry

import (
	"math"
	"math/rand"
	"time"
)

// DefaultMaxConcurrent is the fallback concurrency limit for providers
// that don't report backend capacity. Providers that report BackendCapacity
// in heartbeats get a dynamic limit based on their total memory.
const DefaultMaxConcurrent = 4

// MaxConcurrentRequests is kept as an alias for backward compatibility
// with tests and external code that reference the old constant name.
const MaxConcurrentRequests = DefaultMaxConcurrent

// ScoreProvider calculates a routing score for a provider.
// Higher scores indicate better routing candidates.
// Score = (1 - load) * decode_tps * trust_multiplier * reputation * warm_bonus * health_factor
//
// Uses dynamic max based on hardware when backend capacity is reported.
func ScoreProvider(p *Provider, model string) float64 {
	// Providers that have not passed runtime integrity verification score 0
	// and should never be selected for routing.
	p.mu.Lock()
	runtimeVerified := p.RuntimeVerified
	p.mu.Unlock()
	if !runtimeVerified {
		return 0
	}

	// Load: gradient from 0.0 (idle) to 1.0 (at max concurrency).
	// Uses a positive provider-reported slot cap when present, otherwise the
	// legacy provider-level dynamic max.
	p.mu.Lock()
	maxConc := p.maxConcurrencyForModelLocked(model)
	pending := float64(p.pendingLoadForModelLocked(model))
	p.mu.Unlock()
	load := pending / float64(maxConc)
	if load > 1.0 {
		load = 1.0
	}

	// Snapshot mutable fields under lock. These are written by Heartbeat
	// and SetTrustLevel from other goroutines.
	p.mu.Lock()
	decodeTPS := p.DecodeTPS
	trustLevel := p.TrustLevel
	warmModels := append([]string{}, p.WarmModels...)
	currentModel := p.CurrentModel
	sysMetrics := p.SystemMetrics
	repScore := p.Reputation.Score()
	backendCap := p.BackendCapacity
	p.mu.Unlock()

	// Base decode TPS — when not reported by the provider, estimate from
	// hardware memory bandwidth using sqrt scaling. Linear bandwidth
	// ratios (e.g. 546 vs 300 = 1.8x) create too much routing skew;
	// sqrt dampens this to ~1.35x, giving faster hardware a mild
	// preference while still distributing load across all providers.
	if decodeTPS <= 0 {
		bw := float64(p.Hardware.MemoryBandwidthGBs)
		if bw > 0 {
			decodeTPS = math.Sqrt(bw) // sqrt scaling: 546→23.4, 400→20, 300→17.3, 150→12.2
		} else {
			decodeTPS = 1.0
		}
	}

	trustMul := TrustMultiplier(trustLevel)

	// Warm model bonus: only applies when the provider is IDLE (no pending
	// requests). This prevents a warm provider from monopolizing all traffic.
	// Once a warm provider has any pending requests, cold providers compete
	// on equal terms — a 20s parallel cold-start beats waiting in a serial
	// queue behind a single warm provider.
	warmBonus := 1.0
	isIdle := pending == 0
	if isIdle {
		for _, wm := range warmModels {
			if wm == model {
				warmBonus = 1.5
				break
			}
		}
		if currentModel == model {
			warmBonus = 1.5
		}
	}

	// Cold-start / crash penalty: apply regardless of load. These represent
	// providers whose backend is DOWN (not just cold in cache). Loading from
	// idle_shutdown takes ~30s, crashed backends may not recover at all.
	if backendCap != nil {
		for _, slot := range backendCap.Slots {
			if slot.Model == model {
				switch slot.State {
				case "idle_shutdown":
					warmBonus = 0.1
				case "crashed":
					warmBonus = 0.05
				}
				break
			}
		}
	}

	// Health factor from live system metrics
	m := sysMetrics

	// Memory pressure: linear penalty. At 0.9 -> factor 0.1
	memFactor := 1.0 - m.MemoryPressure
	if memFactor < 0.1 {
		memFactor = 0.1
	}

	// CPU usage: gentle penalty (max 50% reduction at full load)
	cpuFactor := 1.0 - (m.CPUUsage * 0.5)

	// Thermal: step penalties
	thermalFactor := 1.0
	switch m.ThermalState {
	case "fair":
		thermalFactor = 0.8
	case "serious":
		thermalFactor = 0.4
	case "critical":
		thermalFactor = 0.0
	}

	healthFactor := memFactor * cpuFactor * thermalFactor

	// GPU memory pressure from backend capacity: penalize providers with
	// high GPU utilization to prefer those with more headroom.
	if backendCap != nil && backendCap.GPUMemoryActiveGB > 0 {
		totalMem := backendCap.TotalMemoryGB
		if totalMem <= 0 {
			totalMem = float64(p.Hardware.MemoryGB)
		}
		if totalMem > 0 {
			gpuUtil := backendCap.GPUMemoryActiveGB / totalMem
			gpuFactor := 1.0 - (gpuUtil * 0.5) // max 50% penalty at full GPU
			if gpuFactor < 0.1 {
				gpuFactor = 0.1
			}
			healthFactor *= gpuFactor
		}
	}

	return (1.0 - load) * decodeTPS * trustMul * repScore * warmBonus * healthFactor
}

// FindProvider selects an available provider for the given model using
// intelligent scoring based on benchmark data, trust level, reputation,
// warm model cache, and backend capacity. Picks the highest-scoring
// provider that has concurrency headroom (dynamic limit based on hardware).
// Optional excludeIDs are provider IDs to skip (e.g. providers that
// already failed for this request during retry).
func (r *Registry) FindProvider(model string, excludeIDs ...string) *Provider {
	return r.FindProviderWithTrust(model, "", excludeIDs...)
}

// FindProviderWithTrust selects a provider with an optional per-request
// minimum trust level. If minTrust is empty, the registry's default
// MinTrustLevel is used. Consumers can request a specific trust level
// (e.g. hardware) to filter providers. Optional excludeIDs are provider
// IDs to skip during selection.
func (r *Registry) FindProviderWithTrust(model string, minTrust TrustLevel, excludeIDs ...string) *Provider {
	r.mu.Lock()
	defer r.mu.Unlock()

	// Build a set of excluded provider IDs for O(1) lookup.
	excludeSet := make(map[string]struct{}, len(excludeIDs))
	for _, id := range excludeIDs {
		excludeSet[id] = struct{}{}
	}

	// Determine effective minimum: max of registry default and per-request
	effectiveMin := r.MinTrustLevel
	if minTrust != "" && trustRank(minTrust) > trustRank(effectiveMin) {
		effectiveMin = minTrust
	}

	// Challenge staleness threshold: providers must have passed a
	// challenge within the last interval + grace period. The challenge
	// interval is 5 minutes, so we allow up to 6 minutes (interval +
	// 1-minute grace) to avoid a gap where providers are unroutable
	// between challenge cycles.
	challengeMaxAge := 6 * time.Minute
	now := time.Now()

	var candidates []*Provider
	for _, p := range r.providers {
		// Skip explicitly excluded providers (failed on previous retry attempts).
		if _, excluded := excludeSet[p.ID]; excluded {
			continue
		}

		p.mu.Lock()
		status := p.Status
		trust := p.TrustLevel
		lastChallenge := p.LastChallengeVerified
		runtimeVerified := p.RuntimeVerified
		privateReady := providerSupportsPrivateTextLocked(p)
		p.mu.Unlock()

		if status == StatusOffline || status == StatusUntrusted {
			continue
		}
		if trustRank(trust) < trustRank(effectiveMin) {
			continue
		}
		if !runtimeVerified || !privateReady {
			continue
		}
		if lastChallenge.IsZero() || now.Sub(lastChallenge) > challengeMaxAge {
			continue
		}
		p.mu.Lock()
		hasHeadroom := p.hasConcurrencyHeadroomForModelLocked(model)
		p.mu.Unlock()
		if !hasHeadroom {
			continue
		}
		if r.providerServesCatalogModelLocked(p, model) {
			candidates = append(candidates, p)
		}
	}

	if len(candidates) == 0 {
		return nil
	}

	// Score all candidates and pick the highest.
	bestIdx := 0
	bestScore := ScoreProvider(candidates[0], model)
	for i := 1; i < len(candidates); i++ {
		s := ScoreProvider(candidates[i], model)
		if s > bestScore {
			bestScore = s
			bestIdx = i
		}
	}

	// When multiple candidates tie for the best score (common when all
	// providers have the same hardware/TPS and load), randomly pick among
	// them to distribute load instead of always picking the first one.
	var ties []*Provider
	for _, c := range candidates {
		if ScoreProvider(c, model) >= bestScore-0.001 {
			ties = append(ties, c)
		}
	}
	var selected *Provider
	if len(ties) > 1 {
		selected = ties[rand.Intn(len(ties))]
	} else {
		selected = candidates[bestIdx]
	}

	selected.mu.Lock()
	selected.Status = StatusServing
	selected.mu.Unlock()

	return selected
}
