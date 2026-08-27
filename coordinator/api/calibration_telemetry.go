package api

import (
	"strings"
	"sync"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

const capacitySampleInterval = time.Minute

type capacitySampler struct {
	mu       sync.Mutex
	last     map[string]time.Time
	interval time.Duration
}

func newCapacitySampler() *capacitySampler {
	return &capacitySampler{
		last:     make(map[string]time.Time),
		interval: capacitySampleInterval,
	}
}

func (c *capacitySampler) shouldSample(id string, now time.Time) bool {
	if c == nil || id == "" {
		return false
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if prev, ok := c.last[id]; ok && now.Sub(prev) < c.interval {
		return false
	}
	c.last[id] = now
	return true
}

func (s *Server) maybeRecordCapacitySample(provider *registry.Provider) {
	if s == nil || s.store == nil || provider == nil {
		return
	}
	if s.capacitySampler == nil {
		s.capacitySampler = newCapacitySampler()
	}
	if !s.capacitySampler.shouldSample(provider.ID, time.Now()) {
		return
	}
	sample := capacitySampleFromProvider(provider)
	if sample == nil {
		return
	}
	s.submitTelemetry("recordCapacitySample", func() {
		_ = s.store.RecordProviderCapacitySample(sample)
	})
}

func capacitySampleFromProvider(p *registry.Provider) *store.ProviderCapacitySample {
	if p == nil {
		return nil
	}
	p.Mu().Lock()
	defer p.Mu().Unlock()
	sample := &store.ProviderCapacitySample{
		ProviderID:         p.ID,
		ProviderVersion:    p.Version,
		ProviderStatus:     string(p.Status),
		ProviderTrustLevel: string(p.TrustLevel),
		HardwareChipFamily: p.Hardware.ChipFamily,
		HardwareTier:       p.Hardware.ChipTier,
		MemoryGB:           p.Hardware.MemoryGB,
		CurrentModel:       p.CurrentModel,
		WarmModelCount:     len(p.WarmModels),
		MemoryPressure:     p.SystemMetrics.MemoryPressure,
		CPUUsage:           p.SystemMetrics.CPUUsage,
		ThermalState:       p.SystemMetrics.ThermalState,
		CreatedAt:          time.Now().UTC(),
	}
	if p.BackendCapacity != nil {
		sample.SlotCount = len(p.BackendCapacity.Slots)
		sample.GPUMemoryActiveGB = p.BackendCapacity.GPUMemoryActiveGB
		sample.GPUMemoryPeakGB = p.BackendCapacity.GPUMemoryPeakGB
		sample.GPUMemoryCacheGB = p.BackendCapacity.GPUMemoryCacheGB
		if p.BackendCapacity.FreeForLoadGB != nil {
			sample.FreeForLoadGB = *p.BackendCapacity.FreeForLoadGB
		}
		var decodeSum float64
		var decodeN int
		for _, slot := range p.BackendCapacity.Slots {
			sample.BackendRunning += int(slot.NumRunning)
			sample.BackendWaiting += int(slot.NumWaiting)
			sample.ActiveTokenUsed += slot.ActiveTokenBudgetUsed
			sample.ActiveTokenMax += slot.ActiveTokenBudgetMax
			sample.QueuedTokenBudget += slot.QueuedTokenBudget
			if slot.ObservedDecodeTPS > 0 {
				decodeSum += slot.ObservedDecodeTPS
				decodeN++
			}
			if slot.WedgeSuspected {
				sample.WedgeSuspected = true
			}
		}
		if decodeN > 0 {
			sample.ObservedDecodeTPS = decodeSum / float64(decodeN)
		}
	}
	return sample
}

func applyCacheUsageTelemetry(out *store.InferenceRouteOutcome, usage protocol.UsageInfo) {
	if out == nil || usage.CacheOutcome == "" {
		return
	}
	out.CacheOutcome = usage.CacheOutcome
	out.CacheTier = usage.CacheTier
	out.CachedTokens = usage.CachedTokens
	out.PrefillTokensSaved = usage.PrefillTokensSaved
	out.CacheStageMs = usage.CacheStageMs
}

func applyOutcomeDimensions(out *store.InferenceRouteOutcome) {
	if out == nil || out.FinalStatus == "" {
		return
	}
	switch out.FinalStatus {
	case finalStatusSuccess:
		out.ClientOutcome = "completed"
		out.ProviderOutcome = "completed"
		if out.CostMicroUSD == 0 {
			out.BillingOutcome = "zero_cost"
		} else {
			out.BillingOutcome = "charged"
		}
		out.ResponseCommitted = true
	case finalStatusPartialSuccess:
		out.ResponseCommitted = true
		switch out.ErrorClass {
		case errorClassClientGoneAfterCommitCompleted:
			out.ClientOutcome = "cancelled_after_commit"
			out.ProviderOutcome = "completed"
			out.BillingOutcome = "charged"
		case "client_gone_after_commit_provider_error":
			out.ClientOutcome = "cancelled_after_commit"
			out.ProviderOutcome = "error"
			out.BillingOutcome = "refunded"
		case "no_terminal_after_cancel":
			out.ClientOutcome = "cancelled_after_commit"
			out.ProviderOutcome = "no_terminal"
			out.BillingOutcome = "refunded"
		case "provider_error_after_commit":
			out.ClientOutcome = "partial"
			out.ProviderOutcome = "error"
			out.BillingOutcome = "refunded"
		case "provider_disconnect_after_commit":
			out.ClientOutcome = "partial"
			out.ProviderOutcome = "disconnect"
			out.BillingOutcome = "refunded"
		case "stream_timeout_after_commit":
			out.ClientOutcome = "partial"
			out.ProviderOutcome = "timeout"
			out.BillingOutcome = "refunded"
		default:
			out.ClientOutcome = "partial"
			out.ProviderOutcome = "error"
			out.BillingOutcome = "refunded"
		}
	case finalStatusCancelled:
		out.ClientOutcome = "cancelled"
		out.ProviderOutcome = "cancelled"
		out.BillingOutcome = "refunded"
	case finalStatusTimeout:
		out.ClientOutcome = "timeout"
		out.ProviderOutcome = "timeout"
		out.BillingOutcome = "refunded"
	case finalStatusError:
		out.ClientOutcome = "error"
		out.ProviderOutcome = "error"
		out.BillingOutcome = "refunded"
	}
}

func (s *Server) emitPredictionTelemetry(pr *registry.PendingRequest, out *store.InferenceRouteOutcome) {
	if s == nil || pr == nil || out == nil {
		return
	}
	tags := []string{}
	if pr.Model != "" {
		tags = append(tags, "model:"+pr.Model)
	}
	if pr.PredictedTTFTMs > 0 && out.ActualTTFTMs > 0 {
		s.ddHistogram("routing.ttft_error_ms", out.ActualTTFTMs-pr.PredictedTTFTMs, tags)
		s.ddHistogram("routing.ttft_ratio", out.ActualTTFTMs/pr.PredictedTTFTMs, tags)
	}
	if pr.PredictedEffectiveTPS > 0 && out.ActualDecodeTPS > 0 {
		s.ddHistogram("routing.decode_tps_ratio", out.ActualDecodeTPS/pr.PredictedEffectiveTPS, tags)
	}
	if pr.PredictedCostMs > 0 && out.TotalDurationMs > 0 {
		s.ddHistogram("routing.duration_vs_cost_ms", out.TotalDurationMs-pr.PredictedCostMs, tags)
	}
	if pr.EstimatedPromptTokens > 0 && out.PromptTokens > 0 {
		s.ddHistogram("routing.prompt_token_estimate_error", float64(out.PromptTokens-pr.EstimatedPromptTokens), tags)
	}
}

func routeCandidatesFromDecision(requestID string, attempt int, candidates []registry.RouteCandidateSnapshot) []store.InferenceRouteCandidateRecord {
	if requestID == "" || len(candidates) == 0 {
		return nil
	}
	now := time.Now().UTC()
	out := make([]store.InferenceRouteCandidateRecord, 0, len(candidates))
	for _, c := range candidates {
		if c.ProviderID == "" {
			continue
		}
		out = append(out, store.InferenceRouteCandidateRecord{
			RequestID:           requestID,
			Attempt:             attempt,
			ProviderID:          c.ProviderID,
			Rank:                c.Rank,
			Selected:            c.Selected,
			Eligible:            c.Eligible,
			RejectionReason:     c.RejectionReason,
			CostMs:              c.CostMs,
			StateMs:             c.StateMs,
			QueueMs:             c.QueueMs,
			PendingMs:           c.PendingMs,
			BacklogMs:           c.BacklogMs,
			ThisReqMs:           c.ThisReqMs,
			HealthMs:            c.HealthMs,
			CapacityRateMs:      c.CapacityRateMs,
			TTFTMs:              c.TTFTMs,
			EffectiveQueue:      c.EffectiveQueue,
			EffectiveTPS:        c.EffectiveTPS,
			StaticTPS:           c.StaticTPS,
			EffectivePrefillTPS: c.EffectivePrefillTPS,
			StaticPrefillTPS:    c.StaticPrefillTPS,
			BatchSize:           c.BatchSize,
			ChipFamily:          c.ChipFamily,
			HardwareTier:        c.HardwareTier,
			MemoryGB:            c.MemoryGB,
			SlotState:           c.SlotState,
			MemoryPressure:      c.MemoryPressure,
			ThermalState:        c.ThermalState,
			GPUMemoryActiveGB:   c.GPUMemoryActiveGB,
			FreeForLoadGB:       c.FreeForLoadGB,
			WedgeSuspected:      c.WedgeSuspected,
			AffinityApplied:     c.AffinityApplied,
			AffinityDiscountMs:  c.AffinityDiscountMs,
			CapacityRejectRate:  c.CapacityRejectRate,
			CreatedAt:           now,
		})
	}
	return out
}

func applyBillingSettlement(out *store.InferenceRouteOutcome, reserved, settled, overage, refund int64) {
	if out == nil {
		return
	}
	out.ReservedMicroUSD = reserved
	out.SettledMicroUSD = settled
	out.OverageMicroUSD = overage
	out.RefundMicroUSD = refund
}

func terminalSourceFor(status, class string) string {
	lowerClass := strings.ToLower(strings.TrimSpace(class))
	switch {
	case strings.Contains(lowerClass, "client_gone"):
		return "client"
	case strings.Contains(lowerClass, "speculative"):
		return "coordinator"
	case strings.EqualFold(strings.TrimSpace(status), finalStatusTimeout) || strings.Contains(lowerClass, "timeout"):
		return "coordinator_timeout"
	case strings.Contains(lowerClass, "provider"):
		return "provider"
	case strings.EqualFold(strings.TrimSpace(status), finalStatusSuccess):
		return "provider"
	case strings.EqualFold(strings.TrimSpace(status), finalStatusCancelled):
		return "client"
	default:
		return "coordinator"
	}
}

func coarseRegion(loc *store.ProviderLocation) string {
	if loc == nil {
		return ""
	}
	if loc.RegionCode != "" {
		return loc.RegionCode
	}
	if loc.CountryCode != "" {
		return loc.CountryCode
	}
	return loc.Region
}

func (d *dispatchState) telemetryEndpoint() string {
	if d == nil {
		return ""
	}
	if d.consumerEndpoint != "" {
		return d.consumerEndpoint
	}
	if d.isResponsesAPI {
		return "/v1/responses"
	}
	return "/v1/chat/completions"
}
