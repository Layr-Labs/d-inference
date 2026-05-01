package registry

import (
	"math"
	"math/rand"
	"sort"

	"github.com/eigeninference/coordinator/internal/protocol"
)

// RoutingReplayStrategy names a local-only simulator routing policy.
type RoutingReplayStrategy string

const (
	RoutingStrategyCurrentCostModel RoutingReplayStrategy = "current_cost_model"
	RoutingStrategyRoundRobin       RoutingReplayStrategy = "round_robin"
	RoutingStrategyLeastActive      RoutingReplayStrategy = "least_active"
	// RoutingStrategyLeastMetric intentionally uses only stale snapshot metrics
	// (CPU/memory) and ignores assignments made during the replay. It models the
	// Riot/Valorant failure mode where a burst herds onto the machine that looked
	// best in the last heartbeat.
	RoutingStrategyLeastMetric   RoutingReplayStrategy = "least_metric"
	RoutingStrategyRandomNearTie RoutingReplayStrategy = "random_near_tie"
)

// RoutingReplayProvider is the synthetic provider snapshot used by the replay
// harness. It is intentionally small and independent of live registry state.
type RoutingReplayProvider struct {
	ID             string
	Model          string
	DecodeTPS      float64
	PrefillTPS     float64
	MaxConcurrency int
	CPUUsage       float64
	MemoryPressure float64
	ThermalState   string
	TotalMemoryGB  float64
	GPUActiveGB    float64
}

// RoutingReplayRequest is a synthetic request arrival.
type RoutingReplayRequest struct {
	ID           string
	Model        string
	ArrivalMs    float64
	PromptTokens int
	MaxTokens    int
	TimeoutMs    float64
}

// RoutingReplayScenario contains all inputs for a deterministic replay.
type RoutingReplayScenario struct {
	Providers  []RoutingReplayProvider
	Requests   []RoutingReplayRequest
	Strategies []RoutingReplayStrategy
	RandomSeed int64
}

// RoutingReplayAssignment records one replayed routing decision.
type RoutingReplayAssignment struct {
	RequestID      string
	ProviderID     string
	ArrivalMs      float64
	StartMs        float64
	TTFTMs         float64
	TotalLatencyMs float64
	OverCapacity   bool
	TimedOut       bool
}

// RoutingReplayMetrics contains per-strategy replay output.
type RoutingReplayMetrics struct {
	Strategy              RoutingReplayStrategy
	Assignments           []RoutingReplayAssignment
	ProviderRequestCounts map[string]int
	ProviderUtilization   map[string]float64
	TTFTP50Ms             float64
	TTFTP95Ms             float64
	TTFTP99Ms             float64
	TotalLatencyP50Ms     float64
	TotalLatencyP95Ms     float64
	TotalLatencyP99Ms     float64
	TotalLatencyMs        float64
	TimeoutCount          int
	OverCapacityCount     int
}

// ReplayRoutingScenario replays synthetic request arrivals against provider
// snapshots for each requested strategy. It has no side effects on the live
// registry and is intended for local unit tests and routing experiments.
func ReplayRoutingScenario(s RoutingReplayScenario) map[RoutingReplayStrategy]RoutingReplayMetrics {
	strategies := s.Strategies
	if len(strategies) == 0 {
		strategies = []RoutingReplayStrategy{RoutingStrategyCurrentCostModel, RoutingStrategyRoundRobin, RoutingStrategyLeastActive, RoutingStrategyLeastMetric}
	}
	out := make(map[RoutingReplayStrategy]RoutingReplayMetrics, len(strategies))
	for _, strategy := range strategies {
		out[strategy] = replayRoutingStrategy(s, strategy)
	}
	return out
}

type replayProviderState struct {
	spec      RoutingReplayProvider
	active    []replayActiveRequest
	busyMs    float64
	rrCursor  int
	inputSlot int
}

type replayActiveRequest struct {
	endMs     float64
	maxTokens int
}

func replayRoutingStrategy(s RoutingReplayScenario, strategy RoutingReplayStrategy) RoutingReplayMetrics {
	providers := make([]*replayProviderState, 0, len(s.Providers))
	for i, p := range s.Providers {
		if p.ID == "" {
			p.ID = string(rune('a' + i))
		}
		if p.DecodeTPS <= 0 {
			p.DecodeTPS = 1
		}
		if p.PrefillTPS <= 0 {
			p.PrefillTPS = p.DecodeTPS * 4
		}
		if p.MaxConcurrency <= 0 {
			p.MaxConcurrency = DefaultMaxConcurrent
		}
		if p.ThermalState == "" {
			p.ThermalState = "nominal"
		}
		providers = append(providers, &replayProviderState{spec: p, inputSlot: i})
	}

	requests := append([]RoutingReplayRequest(nil), s.Requests...)
	sort.SliceStable(requests, func(i, j int) bool {
		if requests[i].ArrivalMs == requests[j].ArrivalMs {
			return requests[i].ID < requests[j].ID
		}
		return requests[i].ArrivalMs < requests[j].ArrivalMs
	})

	seed := s.RandomSeed
	if seed == 0 {
		seed = 1
	}
	rng := rand.New(rand.NewSource(seed))
	counts := make(map[string]int, len(providers))
	util := make(map[string]float64, len(providers))
	assignments := make([]RoutingReplayAssignment, 0, len(requests))
	var rr int

	for _, req := range requests {
		if req.MaxTokens <= 0 {
			req.MaxTokens = defaultRequestedMaxTokens
		}
		for _, p := range providers {
			p.completeThrough(req.ArrivalMs)
		}

		selected := selectReplayProvider(providers, req, strategy, rr, rng)
		if selected == nil {
			assignments = append(assignments, RoutingReplayAssignment{RequestID: req.ID, ArrivalMs: req.ArrivalMs, OverCapacity: true, TimedOut: true})
			continue
		}
		if strategy == RoutingStrategyRoundRobin {
			rr = selected.inputSlot + 1
		}

		activeBefore := len(selected.active)
		overCapacity := activeBefore >= selected.spec.MaxConcurrency
		start := req.ArrivalMs
		if overCapacity {
			start = selected.nextAvailableMs(req.ArrivalMs)
		}
		prefillMs := float64(req.PromptTokens) / selected.spec.PrefillTPS * 1000
		decodeTPS := effectiveDecodeTPS(selected.spec.DecodeTPS, minInt(activeBefore, selected.spec.MaxConcurrency))
		decodeMs := float64(req.MaxTokens) / decodeTPS * 1000
		serviceMs := prefillMs + decodeMs
		end := start + serviceMs
		ttft := (start - req.ArrivalMs) + prefillMs
		latency := end - req.ArrivalMs
		timedOut := req.TimeoutMs > 0 && ttft > req.TimeoutMs

		selected.active = append(selected.active, replayActiveRequest{endMs: end, maxTokens: req.MaxTokens})
		selected.busyMs += serviceMs
		counts[selected.spec.ID]++
		assignments = append(assignments, RoutingReplayAssignment{
			RequestID:      req.ID,
			ProviderID:     selected.spec.ID,
			ArrivalMs:      req.ArrivalMs,
			StartMs:        start,
			TTFTMs:         ttft,
			TotalLatencyMs: latency,
			OverCapacity:   overCapacity,
			TimedOut:       timedOut,
		})
	}

	var horizon float64
	for _, req := range requests {
		if req.ArrivalMs > horizon {
			horizon = req.ArrivalMs
		}
	}
	for _, p := range providers {
		for _, a := range p.active {
			if a.endMs > horizon {
				horizon = a.endMs
			}
		}
	}
	if horizon <= 0 {
		horizon = 1
	}
	for _, p := range providers {
		counts[p.spec.ID] += 0
		util[p.spec.ID] = p.busyMs / horizon
	}

	metrics := RoutingReplayMetrics{
		Strategy:              strategy,
		Assignments:           assignments,
		ProviderRequestCounts: counts,
		ProviderUtilization:   util,
	}
	var ttfts, latencies []float64
	for _, a := range assignments {
		if a.ProviderID == "" {
			metrics.OverCapacityCount++
			metrics.TimeoutCount++
			continue
		}
		ttfts = append(ttfts, a.TTFTMs)
		latencies = append(latencies, a.TotalLatencyMs)
		metrics.TotalLatencyMs += a.TotalLatencyMs
		if a.OverCapacity {
			metrics.OverCapacityCount++
		}
		if a.TimedOut {
			metrics.TimeoutCount++
		}
	}
	metrics.TTFTP50Ms = percentile(ttfts, 0.50)
	metrics.TTFTP95Ms = percentile(ttfts, 0.95)
	metrics.TTFTP99Ms = percentile(ttfts, 0.99)
	metrics.TotalLatencyP50Ms = percentile(latencies, 0.50)
	metrics.TotalLatencyP95Ms = percentile(latencies, 0.95)
	metrics.TotalLatencyP99Ms = percentile(latencies, 0.99)
	return metrics
}

func (p *replayProviderState) completeThrough(nowMs float64) {
	kept := p.active[:0]
	for _, a := range p.active {
		if a.endMs > nowMs {
			kept = append(kept, a)
		}
	}
	p.active = kept
}

func (p *replayProviderState) nextAvailableMs(arrivalMs float64) float64 {
	if len(p.active) < p.spec.MaxConcurrency {
		return arrivalMs
	}
	ends := make([]float64, 0, len(p.active))
	for _, a := range p.active {
		ends = append(ends, a.endMs)
	}
	sort.Float64s(ends)
	idx := len(p.active) - p.spec.MaxConcurrency
	if idx < 0 {
		idx = 0
	}
	if ends[idx] < arrivalMs {
		return arrivalMs
	}
	return ends[idx]
}

func selectReplayProvider(providers []*replayProviderState, req RoutingReplayRequest, strategy RoutingReplayStrategy, rr int, rng *rand.Rand) *replayProviderState {
	eligible := make([]*replayProviderState, 0, len(providers))
	for _, p := range providers {
		if p.spec.Model == "" || p.spec.Model == req.Model {
			eligible = append(eligible, p)
		}
	}
	if len(eligible) == 0 {
		return nil
	}

	switch strategy {
	case RoutingStrategyRoundRobin:
		for i := 0; i < len(providers); i++ {
			p := providers[(rr+i)%len(providers)]
			if (p.spec.Model == "" || p.spec.Model == req.Model) && len(p.active) < p.spec.MaxConcurrency {
				return p
			}
		}
		return eligible[rr%len(eligible)]
	case RoutingStrategyLeastActive:
		return minReplayProvider(eligible, func(p *replayProviderState) float64 { return float64(len(p.active)) })
	case RoutingStrategyLeastMetric:
		return minReplayProvider(eligible, func(p *replayProviderState) float64 { return p.spec.CPUUsage + p.spec.MemoryPressure })
	case RoutingStrategyRandomNearTie:
		costs := replayCostCandidates(eligible, req)
		if len(costs) == 0 {
			return minReplayProvider(eligible, func(p *replayProviderState) float64 { return float64(len(p.active)) })
		}
		best := costs[0].cost
		pool := make([]*replayProviderState, 0, len(costs))
		for _, c := range costs {
			if math.Abs(c.cost-best) <= nearTieCostWindowMs {
				pool = append(pool, c.provider)
			}
		}
		return pool[rng.Intn(len(pool))]
	case RoutingStrategyCurrentCostModel:
		fallthrough
	default:
		costs := replayCostCandidates(eligible, req)
		if len(costs) == 0 {
			return nil
		}
		return costs[0].provider
	}
}

type replayCostCandidate struct {
	provider *replayProviderState
	cost     float64
}

func replayCostCandidates(providers []*replayProviderState, req RoutingReplayRequest) []replayCostCandidate {
	out := make([]replayCostCandidate, 0, len(providers))
	reg := &Registry{}
	for _, p := range providers {
		if len(p.active) >= p.spec.MaxConcurrency {
			continue
		}
		pendingTokens := 0
		maxPotential := int64(0)
		for _, a := range p.active {
			pendingTokens += a.maxTokens
			maxPotential += int64(a.maxTokens)
		}
		snap := routingSnapshot{
			provider:           &Provider{ID: p.spec.ID},
			model:              req.Model,
			slotState:          "running",
			totalPending:       len(p.active),
			pendingForModel:    len(p.active),
			pendingMaxTokens:   pendingTokens,
			backendRunning:     len(p.active),
			maxTokensPotential: maxPotential,
			decodeTPS:          p.spec.DecodeTPS,
			prefillTPS:         p.spec.PrefillTPS,
			systemMetrics: protocol.SystemMetrics{
				MemoryPressure: p.spec.MemoryPressure,
				CPUUsage:       p.spec.CPUUsage,
				ThermalState:   p.spec.ThermalState,
			},
			gpuMemoryActiveGB: p.spec.GPUActiveGB,
			totalMemoryGB:     p.spec.TotalMemoryGB,
			modelLoaded:       true,
		}
		candidate, _, ok := reg.buildCandidateWithReason(snap, &PendingRequest{
			RequestID:             req.ID,
			Model:                 req.Model,
			EstimatedPromptTokens: req.PromptTokens,
			RequestedMaxTokens:    req.MaxTokens,
		})
		if ok {
			out = append(out, replayCostCandidate{provider: p, cost: candidate.costMs})
		}
	}
	sort.SliceStable(out, func(i, j int) bool {
		if out[i].cost == out[j].cost {
			if len(out[i].provider.active) == len(out[j].provider.active) {
				return out[i].provider.spec.ID < out[j].provider.spec.ID
			}
			return len(out[i].provider.active) < len(out[j].provider.active)
		}
		return out[i].cost < out[j].cost
	})
	return out
}

func minReplayProvider(providers []*replayProviderState, score func(*replayProviderState) float64) *replayProviderState {
	var best *replayProviderState
	var bestScore float64
	for _, p := range providers {
		s := score(p)
		if best == nil || s < bestScore || (s == bestScore && p.spec.ID < best.spec.ID) {
			best = p
			bestScore = s
		}
	}
	return best
}

func percentile(values []float64, q float64) float64 {
	if len(values) == 0 {
		return 0
	}
	copyVals := append([]float64(nil), values...)
	sort.Float64s(copyVals)
	idx := int(math.Ceil(q*float64(len(copyVals)))) - 1
	if idx < 0 {
		idx = 0
	}
	if idx >= len(copyVals) {
		idx = len(copyVals) - 1
	}
	return copyVals[idx]
}

func minInt(a, b int) int {
	if a < b {
		return a
	}
	return b
}
