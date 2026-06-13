package registry

import (
	"context"
	"math"
	"sort"
	"sync"
	"time"
)

// WarmingPlanner turns demand forecasts into concrete load_model actions.
// It runs on its own ticker so warming decisions are independent of provider
// heartbeat timing.
type WarmingPlanner struct {
	cfg        WarmingConfig
	forecaster *DemandForecaster
	registry   *Registry
	logger     Logger

	mu sync.Mutex
	// lastWarmAt tracks when a provider-model pair was last observed warm or
	// successfully loaded. Used for sticky assignments and minimum warm time.
	lastWarmAt map[string]time.Time // key: "providerID:modelID"
	stop       chan struct{}
	wg         sync.WaitGroup
}

// Logger is the minimal logging interface used by the planner.
type Logger interface {
	Debug(msg string, args ...any)
	Info(msg string, args ...any)
	Warn(msg string, args ...any)
	Error(msg string, args ...any)
}

// NewWarmingPlanner creates a planner. Call Start to begin the ticker.
func NewWarmingPlanner(cfg WarmingConfig, forecaster *DemandForecaster, registry *Registry, logger Logger) *WarmingPlanner {
	if logger == nil {
		logger = noopLogger{}
	}
	return &WarmingPlanner{
		cfg:        cfg,
		forecaster: forecaster,
		registry:   registry,
		logger:     logger,
		lastWarmAt: make(map[string]time.Time),
		stop:       make(chan struct{}),
	}
}

// Start begins the planner ticker. Safe to call multiple times; subsequent calls
// are no-ops.
func (p *WarmingPlanner) Start() {
	if !p.cfg.Enabled {
		return
	}
	p.mu.Lock()
	if p.stop == nil {
		p.stop = make(chan struct{})
	}
	p.mu.Unlock()

	p.wg.Add(1)
	go func() {
		defer p.wg.Done()
		ticker := time.NewTicker(p.cfg.PlannerInterval)
		defer ticker.Stop()
		for {
			select {
			case <-ticker.C:
				p.tick()
			case <-p.stop:
				return
			}
		}
	}()
}

// Stop shuts down the planner ticker.
func (p *WarmingPlanner) Stop() {
	p.mu.Lock()
	if p.stop != nil {
		close(p.stop)
		p.stop = nil
	}
	p.mu.Unlock()
	p.wg.Wait()
}

// RecordWarm records that a provider-model pair is currently warm.
func (p *WarmingPlanner) RecordWarm(providerID, modelID string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.lastWarmAt[providerID+":"+modelID] = time.Now()
}

func (p *WarmingPlanner) tick() {
	now := time.Now()
	ctx := context.Background()
	metrics := p.registry.metrics()

	p.registry.mu.RLock()
	queuedModels := p.registry.queue.QueuedModels()
	p.registry.mu.RUnlock()

	// Include models with any demand signal, not just queued ones.
	models := p.forecaster.ModelsWithDemand()
	for _, m := range queuedModels {
		found := false
		for _, existing := range models {
			if existing == m {
				found = true
				break
			}
		}
		if !found {
			models = append(models, m)
		}
	}

	if len(models) == 0 {
		return
	}

	// Emit per-model forecast and warm-count metrics before planning.
	for _, model := range models {
		forecast := p.forecaster.Forecast(ctx, model)
		metrics.Gauge("warming.forecasted_rps", forecast.RequestsPerSecond, []string{"model:" + model})
		metrics.Gauge("warming.forecast_confidence", forecast.Confidence, []string{"model:" + model})
		warmCount := p.countWarmProvidersLocked(model, now)
		metrics.Gauge("warming.actual_warm_count", float64(warmCount), []string{"model:" + model})
		p.registry.mu.RLock()
		queueSize := p.registry.queue.QueueSize(model)
		p.registry.mu.RUnlock()
		metrics.Gauge("request_queue.adaptive_max_size", float64(p.registry.queue.MaxSizeFor(model)), []string{"model:" + model})
		metrics.Gauge("request_queue.depth", float64(queueSize), []string{"model:" + model})
	}

	actions := p.planLoads(ctx, models, now)
	if len(actions) == 0 {
		return
	}

	p.registry.mu.Lock()
	for _, action := range actions {
		key := action.providerID + ":" + action.modelID
		if _, ok := p.registry.pendingModelLoads[key]; ok {
			continue
		}
		p.registry.pendingModelLoads[key] = now.Add(pendingModelLoadTTL)
		p.registry.SendLoadModel(action.providerID, action.modelID)
		metrics.Incr("warming.load_commands_sent", []string{"model:" + action.modelID})
	}
	p.registry.mu.Unlock()
}

// planLoads computes the load_model actions for the given models.
func (p *WarmingPlanner) planLoads(ctx context.Context, models []string, now time.Time) []modelLoadAction {
	var actions []modelLoadAction
	selectedProviders := make(map[string]struct{})

	for _, model := range models {
		forecast := p.forecaster.Forecast(ctx, model)
		if forecast.RequestsPerSecond <= 0 && forecast.QueuedRPS <= 0 {
			continue
		}

		p.registry.mu.RLock()
		currentWarm := p.countWarmProvidersLocked(model, now)
		p.registry.mu.RUnlock()

		target := p.targetWarmCount(forecast)
		if currentWarm >= target {
			continue
		}

		needed := target - currentWarm
		if needed > p.cfg.MaxLoadsPerModelPerTick {
			needed = p.cfg.MaxLoadsPerModelPerTick
		}

		for i := 0; i < needed; i++ {
			providerID := p.pickProviderForWarmLocked(model, selectedProviders, now)
			if providerID == "" {
				break
			}
			selectedProviders[providerID] = struct{}{}
			actions = append(actions, modelLoadAction{providerID: providerID, modelID: model})
		}
	}

	return actions
}

// targetWarmCount converts a demand forecast into a desired number of warm
// providers for the model.
func (p *WarmingPlanner) targetWarmCount(f DemandForecast) int {
	// Use recent rate + queued demand as the load driver. Historical baseline
	// alone should not create many warm providers.
	demandRPS := f.RecentRPS + f.QueuedRPS
	if demandRPS <= 0 {
		return 0
	}

	// Each provider is expected to handle utilization * its max concurrency.
	// For simplicity, assume a nominal concurrency of 6 when token budgets are
	// not available. Token-budget providers will be handled more precisely in
	// future iterations.
	nominalConcurrency := 6.0
	capacityPerProvider := nominalConcurrency * p.cfg.TargetUtilization
	target := int(math.Ceil(demandRPS / capacityPerProvider))

	// Keep at least one provider warm if there is any queued demand.
	if f.QueuedRPS > 0 && target < 1 {
		target = 1
	}

	// Cap to avoid warming the entire fleet for a spike.
	maxWarm := 8
	if target > maxWarm {
		target = maxWarm
	}

	return target
}

// countWarmProvidersLocked returns how many providers currently have the model
// warm and routing-eligible. Caller must hold r.mu (read or write).
func (p *WarmingPlanner) countWarmProvidersLocked(model string, now time.Time) int {
	count := 0
	for _, provider := range p.registry.providers {
		provider.mu.Lock()
		warm := p.registry.providerHasWarmModelLocked(provider, model, now)
		provider.mu.Unlock()
		if warm {
			count++
		}
	}
	return count
}

// pickProviderForWarmLocked selects the best provider to warm for the model.
// Caller must NOT hold r.mu; this method acquires its own locks.
func (p *WarmingPlanner) pickProviderForWarmLocked(model string, selectedProviders map[string]struct{}, now time.Time) string {
	p.registry.mu.RLock()
	defer p.registry.mu.RUnlock()

	type candidate struct {
		id    string
		score float64
	}
	var candidates []candidate

	for id, provider := range p.registry.providers {
		if _, selected := selectedProviders[id]; selected {
			continue
		}
		score, ok := p.scoreWarmCandidateLocked(provider, model, now)
		if !ok {
			continue
		}
		candidates = append(candidates, candidate{id: id, score: score})
	}

	if len(candidates) == 0 {
		return ""
	}

	// Lower score is better.
	sort.Slice(candidates, func(i, j int) bool {
		return candidates[i].score < candidates[j].score
	})
	return candidates[0].id
}

// scoreWarmCandidateLocked scores a provider for warming. Returns ok=false if
// the provider must not be selected. Caller must hold r.mu.
func (p *WarmingPlanner) scoreWarmCandidateLocked(provider *Provider, model string, now time.Time) (float64, bool) {
	provider.mu.Lock()
	defer provider.mu.Unlock()

	// Routing safety gates.
	if provider.Status == StatusOffline || provider.Status == StatusUntrusted {
		return 0, false
	}
	if provider.PrivateOnly {
		return 0, false
	}
	if trustRank(provider.TrustLevel) < trustRank(p.registry.MinTrustLevel) {
		return 0, false
	}
	if !provider.RuntimeVerified {
		return 0, false
	}
	if !p.registry.providerSupportsPrivateTextLocked(provider) {
		return 0, false
	}
	if provider.LastChallengeVerified.IsZero() || now.Sub(provider.LastChallengeVerified) > challengeFreshnessMaxAge {
		return 0, false
	}
	if !p.registry.providerServesCatalogModelLocked(provider, model) {
		return 0, false
	}

	// Already warm for this model?
	if p.registry.providerHasWarmModelLocked(provider, model, now) {
		return 0, false
	}

	// Already loading any model? Avoid swap oscillation.
	if p.registry.providerHasPendingLoad(provider.ID) {
		return 0, false
	}

	// Dispatch-load cooldown for this model.
	if p.registry.dispatchLoadCooldownActiveLocked(provider.ID, model, now) {
		return 0, false
	}

	// Thermal hysteresis: exclude providers that are thermally rejected.
	if provider.thermallyRejectedLocked() {
		return 0, false
	}
	thermal := provider.SystemMetrics.ThermalState

	// Memory gate: static catalog fit first.
	if entry, ok := p.registry.modelCatalog[model]; ok && (entry.MinRAMGB > 0 || entry.SizeGB > 0) {
		if !modelFitsHardware(entry.MinRAMGB, entry.SizeGB, float64(provider.Hardware.MemoryGB)) {
			return 0, false
		}
	}

	var score float64

	// Prefer providers with low current load so the new model can actually serve.
	loadRatio := float64(provider.pendingCount()) / float64(max(1, provider.maxConcurrency()))
	score += loadRatio * 10_000.0

	// Prefer providers with more free memory.
	var totalMem, activeMem float64
	if provider.BackendCapacity != nil {
		totalMem = provider.BackendCapacity.TotalMemoryGB
		activeMem = provider.BackendCapacity.GPUMemoryActiveGB
	}
	if totalMem <= 0 {
		totalMem = float64(provider.Hardware.MemoryGB)
	}
	freeMem := totalMem - activeMem
	if freeMem < 0 {
		freeMem = 0
	}
	if entry, ok := p.registry.modelCatalog[model]; ok && entry.SizeGB > 0 {
		// Penalize if model size exceeds free memory; still allow if total fits
		// (provider will evict).
		if freeMem < entry.SizeGB {
			score += (entry.SizeGB - freeMem) * 1_000.0
		}
	}

	// Penalize thermal stress.
	if thermal == "serious" {
		score += 5_000.0
	} else if thermal == "fair" {
		score += 1_000.0
	}

	// Sticky bonus: provider recently had this model warm.
	p.mu.Lock()
	lastWarm := p.lastWarmAt[provider.ID+":"+model]
	p.mu.Unlock()
	if now.Sub(lastWarm) < 30*time.Minute {
		score -= 2_000.0
	}

	// Prefer faster chips.
	chipScore := chipFamilyRank(provider.Hardware.ChipFamily)
	score -= float64(chipScore) * 200.0

	return score, true
}

// chipFamilyRank returns a higher number for newer/faster chips. This is a
// coarse ordering; the scheduler uses observed TPS when available.
func chipFamilyRank(family string) int {
	switch family {
	case "M3 Max", "M3 Pro", "M3":
		return 6
	case "M2 Ultra", "M2 Max", "M2 Pro", "M2":
		return 5
	case "M1 Ultra", "M1 Max", "M1 Pro":
		return 4
	case "M1":
		return 3
	default:
		return 2
	}
}

type noopLogger struct{}

func (noopLogger) Debug(string, ...any) {}
func (noopLogger) Info(string, ...any)  {}
func (noopLogger) Warn(string, ...any)  {}
func (noopLogger) Error(string, ...any) {}
