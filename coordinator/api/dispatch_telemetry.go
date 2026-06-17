package api

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// routingOutcomeKey returns a stable requestID + attempt identifier used for
// telemetry updates. It prefers the explicit dispatch requestID, falling back
// to the pending request's ID when the dispatch requestID has not been set yet.
func (d *dispatchState) routingOutcomeKey() string {
	if d.requestID != "" {
		return d.requestID
	}
	if d.pr != nil {
		return d.pr.RequestID
	}
	return ""
}

// recordRoutingDecision writes a best-effort snapshot of the scheduler decision
// for the current attempt. It never blocks inference.
func (d *dispatchState) recordRoutingDecision(decision registry.RoutingDecision, dispatchErr, outcomeOverride string) {
	s := d.s
	requestID := d.routingOutcomeKey()

	providerID := ""
	if d.provider != nil {
		providerID = d.provider.ID
	} else if decision.ProviderID != "" {
		providerID = decision.ProviderID
	}

	outcome := outcomeOverride
	if outcome == "" {
		switch {
		case providerID != "":
			outcome = "selected"
		case dispatchErr == errModelTooLarge:
			outcome = "model_too_large"
		case dispatchErr == errTTFTTooSlow:
			outcome = "ttft_429"
		case dispatchErr == "no provider available":
			outcome = "no_provider"
		default:
			outcome = "error"
		}
	}

	keyID := ""
	if d.pr != nil {
		keyID = d.pr.KeyID
	}

	record := &store.InferenceRouteRecord{
		RequestID:               requestID,
		Attempt:                 d.attempt,
		ProviderID:              providerID,
		Model:                   d.model,
		PublicModel:             d.publicModel,
		ConsumerKeyHash:         store.HashKey(d.consumerKey),
		KeyID:                   keyID,
		Outcome:                 outcome,
		CostMs:                  decision.CostMs,
		StateMs:                 decision.StateMs,
		QueueMs:                 decision.QueueMs,
		PendingMs:               decision.PendingMs,
		BacklogMs:               decision.BacklogMs,
		ThisReqMs:               decision.ThisReqMs,
		HealthMs:                decision.HealthMs,
		TTFTMs:                  decision.TTFTMs,
		BestTTFTMs:              decision.BestTTFTMs,
		EffectiveQueue:          decision.EffectiveQueue,
		CandidateCount:          decision.CandidateCount,
		CapacityRejections:      decision.CapacityRejections,
		ModelTooLargeRejections: decision.ModelTooLargeRejections,
		VisionRejections:        decision.VisionRejections,
		TTFTRejections:          decision.TTFTRejections,
		EffectiveTPS:            decision.EffectiveTPS,
		StaticTPS:               decision.StaticTPS,
		EstimatedPromptTokens:   d.estimatedPromptTokens,
		RequestedMaxTokens:      d.requestedMaxTokens,
		RequiresVision:          d.requiresVision,
		HasTools:                d.hasTools,
		SelfRouteOnly:           d.policy.enabled,
		PreferOwner:             d.policy.prefer,
		CacheAffinityKey:        d.cacheAffinityKey,
		CreatedAt:               time.Now(),
		UpdatedAt:               time.Now(),
	}

	if d.provider != nil {
		d.provider.Mu().Lock()
		record.ProviderStatus = string(d.provider.Status)
		record.ProviderTrustLevel = string(d.provider.TrustLevel)
		record.ProviderVersion = d.provider.Version
		record.HardwareChip = d.provider.Hardware.ChipName
		record.HardwareChipFamily = d.provider.Hardware.ChipFamily
		record.HardwareTier = d.provider.Hardware.ChipTier
		record.MemoryGB = d.provider.Hardware.MemoryGB
		record.GPUCores = d.provider.Hardware.GPUCores
		record.CPUCores = d.provider.Hardware.CPUCores.Total
		record.SystemMemoryPressure = d.provider.SystemMetrics.MemoryPressure
		record.SystemCPUUsage = d.provider.SystemMetrics.CPUUsage
		record.SystemThermalState = d.provider.SystemMetrics.ThermalState
		if cap := d.provider.BackendCapacity; cap != nil {
			record.GPUMemoryActiveGB = cap.GPUMemoryActiveGB
			record.GPUMemoryPeakGB = cap.GPUMemoryPeakGB
			record.GPUMemoryCacheGB = cap.GPUMemoryCacheGB
			for _, slot := range cap.Slots {
				if slot.Model == d.model {
					record.SlotState = slot.State
					record.BackendRunning = slot.NumRunning
					record.BackendWaiting = slot.NumWaiting
					record.ActiveTokenBudgetUsed = slot.ActiveTokenBudgetUsed
					record.ActiveTokenBudgetMax = slot.ActiveTokenBudgetMax
					record.QueuedTokenBudget = slot.QueuedTokenBudget
					break
				}
			}
		}
		d.provider.Mu().Unlock()
	}

	s.submitTelemetry("recordInferenceRoute", func() {
		_ = s.store.RecordInferenceRoute(record)
	})
}

// timingMsBetween returns the elapsed milliseconds between two request-lifecycle
// timestamps, or 0 when either endpoint is unset or the interval is non-positive.
// It keeps the latency-decomposition fields defensive: never a negative value,
// never a panic on a zero timestamp.
func timingMsBetween(a, b time.Time) float64 {
	if a.IsZero() || b.IsZero() || !b.After(a) {
		return 0
	}
	return float64(b.Sub(a).Milliseconds())
}

// applyTimingDecomposition fills the coordinator-side latency-decomposition
// fields (ParseMs..DispatchMs) on a routing outcome from the per-request timing
// stamps. Each segment is populated only when both of its endpoints are set
// (timingMsBetween returns 0 otherwise), so a partially-instrumented request
// never records a negative or bogus segment. QueueWaitMs is 0 for requests that
// were dispatched without queueing (QueuedAt unset).
//
// firstChunk is passed in (not read from t.FirstChunkAt) so this can also be
// called from the provider read-loop goroutine (handleComplete) with a value
// obtained via PendingRequest.FirstChunkAtSafe; t.FirstChunkAt itself must only
// be read directly by the dispatch goroutine that owns the request.
func applyTimingDecomposition(out *store.InferenceRouteOutcome, t *registry.RequestTiming, firstChunk time.Time) {
	if out == nil || t == nil {
		return
	}
	out.ParseMs = timingMsBetween(t.ReceivedAt, t.ParsedAt)
	out.ReserveMs = timingMsBetween(t.ParsedAt, t.ReservedAt)
	out.RouteMs = timingMsBetween(t.ReservedAt, t.RoutedAt)
	out.EncryptMs = timingMsBetween(t.RoutedAt, t.EncryptedAt)
	out.QueueWaitMs = timingMsBetween(t.QueuedAt, t.DispatchedAt)
	out.DispatchMs = timingMsBetween(t.DispatchedAt, firstChunk)
}

// successRoutingOutcome builds a success outcome for the committed attempt.
// Token counts are left at zero because the final usage is only available when
// the provider later sends the completion message; handleComplete updates them.
func (d *dispatchState) successRoutingOutcome() *store.InferenceRouteOutcome {
	out := &store.InferenceRouteOutcome{FinalStatus: "success"}
	if d.pr != nil && d.pr.Timing != nil {
		t := d.pr.Timing
		if !t.FirstChunkAt.IsZero() && !t.DispatchedAt.IsZero() {
			ms := float64(t.FirstChunkAt.Sub(t.DispatchedAt).Milliseconds())
			out.ActualTTFTMs = ms
			out.DispatchToFirstChunkMs = ms
		}
		if !t.ReceivedAt.IsZero() {
			out.TotalDurationMs = float64(time.Since(t.ReceivedAt).Milliseconds())
		}
		// Coordinator-side latency decomposition (defensive; zero when unmeasured).
		// Runs on the dispatch goroutine, so reading t.FirstChunkAt directly is safe.
		applyTimingDecomposition(out, t, t.FirstChunkAt)
	}
	return out
}

// errorRoutingOutcome builds an error / timeout / cancelled outcome.
func (d *dispatchState) errorRoutingOutcome(status, class string, code int) *store.InferenceRouteOutcome {
	return &store.InferenceRouteOutcome{
		FinalStatus: status,
		ErrorCode:   code,
		ErrorClass:  class,
	}
}

// providerFailedRoutingOutcome builds the outcome for a POST-DISPATCH provider
// failure: the request had already been admitted to a specific provider (passed
// the admission gate and was dispatched over the WebSocket) and that provider
// then reported an error — including provider-reported OOM / model-load failures
// that surface on pr.ErrorCh. It flags AdmittedButFailed to expose the
// admission-gate mismatch (coordinator said "this provider can serve" but it
// could not). It is intentionally only used from the post-dispatch wait loops;
// pre-dispatch failures (queue reservation DB error, invalid key, keygen, send
// failure) and coordinator-side timeouts are NOT flagged.
func (d *dispatchState) providerFailedRoutingOutcome() *store.InferenceRouteOutcome {
	out := d.errorRoutingOutcome("error", "provider_error", d.lastErrCode)
	out.AdmittedButFailed = true
	return out
}

// updateRoutingOutcome writes a final outcome update for the current attempt
// asynchronously. It is a no-op when there is no request ID to correlate.
func (d *dispatchState) updateRoutingOutcome(outcome *store.InferenceRouteOutcome) {
	requestID := d.routingOutcomeKey()
	if requestID == "" {
		return
	}
	// Capture attempt on the dispatch goroutine: the closure runs on a telemetry
	// sink worker, while run()'s retry loop concurrently advances d.attempt.
	attempt := d.attempt
	d.s.submitTelemetry("updateInferenceRoute", func() {
		_ = d.s.store.UpdateInferenceRouteOutcome(requestID, attempt, outcome)
	})
}
