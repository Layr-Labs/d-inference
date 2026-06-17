package api

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strconv"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/saferun"
)

// waitAccepted runs the post-accept wait for first content (the former
// `acceptedWait` loop). It is entered when the committed provider accepted or held
// preamble but hasn't produced content yet. The budget depends on WHY we're here:
// a genuine AcceptedCh (model reload — legitimately minutes) keeps the full
// inferenceTimeout; a boilerplate-liveness extension past an expired TTFT deadline
// gets only preambleContentTimeout (zero bytes written to the client, so a
// preamble-then-stall provider must fail over instead of pinning for 10 minutes).
func (d *dispatchState) waitAccepted() (outcome dispatchOutcome) {
	s := d.s
	r := d.r
	provider, pr := d.provider, d.pr

	defer func() {
		switch outcome {
		case outcomeCommitted:
			d.updateRoutingOutcome(d.successRoutingOutcome())
		case outcomeRetry:
			if d.lastErrCode == http.StatusGatewayTimeout {
				if d.preambleLiveness {
					d.updateRoutingOutcome(d.errorRoutingOutcome("timeout", "preamble_liveness_timeout", d.lastErrCode))
				} else {
					d.updateRoutingOutcome(d.errorRoutingOutcome("timeout", "accepted_timeout", d.lastErrCode))
				}
			} else {
				// Post-dispatch provider failure (incl. OOM/model-load): admitted but failed.
				d.updateRoutingOutcome(d.providerFailedRoutingOutcome())
			}
		case outcomeClientGone:
			d.updateRoutingOutcome(d.errorRoutingOutcome("cancelled", "client_gone", 0))
		}
	}()

	firstContentBudget := inferenceTimeout
	if d.preambleLiveness {
		firstContentBudget = preambleContentTimeout
	}
	chunkTimer := time.NewTimer(firstContentBudget)
	for {
		select {
		case chunk, ok := <-pr.ChunkCh:
			if ok && len(d.heldChunks) < maxHeldBoilerplate && isBoilerplateChunk(chunk) {
				d.heldChunks = append(d.heldChunks, chunk)
				pr.MarkFirstChunkArrived()
				continue
			}
			chunkTimer.Stop()
			if ok {
				d.firstChunk = chunk
				pr.MarkFirstChunkArrived()
				d.committed = true
			} else {
				// Closed — check for error. Use a short grace
				// period instead of a non-blocking default to
				// close the race where Go's select picks the
				// ChunkCh close before the ErrorCh value (sent
				// by the provider handler before closing ChunkCh).
				select {
				case errMsg := <-pr.ErrorCh:
					d.excludeProviders[provider.ID] = struct{}{}
					s.cancelDispatch(provider, pr)
					d.lastErr = errMsg.Error
					d.lastErrCode = errMsg.StatusCode
					d.lastFailedVersion = failedProviderVersion(provider)
					s.logger.Warn("provider failed after accepting request, retrying",
						"request_id", d.requestID,
						"provider_id", provider.ID,
						"attempt", d.attempt+1,
						"error", errMsg.Error,
					)
					s.emitRequest(r.Context(), protocol.SeverityWarn, d.requestID,
						"provider failed after accepting request, retrying",
						map[string]any{
							"provider_id": provider.ID,
							"attempt":     d.attempt + 1,
							"reason":      "provider_error",
							"status_code": errMsg.StatusCode,
						})
					if s.metrics != nil {
						s.metrics.IncCounter("inference_dispatches_total", MetricLabel{"result", "retry"})
					}
					d.noteDispatchRetry(provider, pr, errMsg.StatusCode, &d.heldChunks)
					d.provider = nil
					d.pr = nil
					return outcomeRetry
				case <-time.After(50 * time.Millisecond):
					d.committed = true
				}
			}
			return outcomeCommitted
		case errMsg := <-pr.ErrorCh:
			chunkTimer.Stop()
			d.excludeProviders[provider.ID] = struct{}{}
			s.cancelDispatch(provider, pr)
			d.lastErr = errMsg.Error
			d.lastErrCode = errMsg.StatusCode
			d.lastFailedVersion = failedProviderVersion(provider)
			s.logger.Warn("provider failed after accepting request, retrying",
				"request_id", d.requestID,
				"provider_id", provider.ID,
				"attempt", d.attempt+1,
				"error", errMsg.Error,
			)
			s.emitRequest(r.Context(), protocol.SeverityWarn, d.requestID,
				"provider failed after accepting request, retrying",
				map[string]any{
					"provider_id": provider.ID,
					"attempt":     d.attempt + 1,
					"reason":      "provider_error",
					"status_code": errMsg.StatusCode,
				})
			if s.metrics != nil {
				s.metrics.IncCounter("inference_dispatches_total", MetricLabel{"result", "retry"})
			}
			d.noteDispatchRetry(provider, pr, errMsg.StatusCode, &d.heldChunks)
			d.provider = nil
			d.pr = nil
			return outcomeRetry
		case <-chunkTimer.C:
			d.excludeProviders[provider.ID] = struct{}{}
			s.registry.RecordWarmPoolTTFTMiss(d.model, firstContentBudget)
			s.cancelDispatch(provider, pr)
			// Accepted-then-silent (or preamble-then-stall) is a
			// provider-at-fault 504 — feed the breaker so a provider
			// that repeatedly acks and stalls enters cooldown instead
			// of soaking retries forever. (504 is one of the breaker's
			// counted codes; this arm is where those 504s originate.)
			s.noteInferenceError(provider.ID, pr, http.StatusGatewayTimeout)
			d.lastErr = "provider accepted but timed out before first chunk"
			if d.preambleLiveness {
				d.lastErr = "provider sent preamble but stalled before first content"
			}
			d.lastErrCode = http.StatusGatewayTimeout
			s.logger.Warn("provider timed out after accepting request, retrying",
				"request_id", d.requestID,
				"provider_id", provider.ID,
				"attempt", d.attempt+1,
				"preamble_liveness", d.preambleLiveness,
			)
			s.emitRequest(r.Context(), protocol.SeverityWarn, d.requestID,
				"provider accepted timeout",
				map[string]any{
					"provider_id": provider.ID,
					"attempt":     d.attempt + 1,
					"reason":      "accepted_timeout",
				})
			if s.metrics != nil {
				s.metrics.IncCounter("inference_dispatches_total", MetricLabel{"result", "timeout"})
			}
			s.ddIncr("inference.dispatches", []string{"status:timeout"})
			d.provider = nil
			d.pr = nil
			return outcomeRetry
		case <-r.Context().Done():
			s.cancelDispatch(provider, pr)
			d.refundReservation()
			return outcomeClientGone
		}
	}
}

// run is the dispatch orchestrator. It replaces the giant inline `for attempt :=
// range maxDispatchAttempts { ... }` block plus the post-loop !committed ladder,
// attestation headers, timing header, settlement defer, and final response handoff.
func (d *dispatchState) run() {
	s := d.s
	w, r := d.w, d.r

	for attempt := range maxDispatchAttempts {
		d.attempt = attempt
		// Each attempt holds preamble chunks from its own provider only.
		d.heldChunks = nil

		switch d.dispatchPrimary() {
		case outcomeRetry:
			continue
		case outcomeFailFast:
			goto exhausted
		case outcomeResponseWritten, outcomeClientGone:
			return
		case outcomeProceed:
			// fall through to the first-chunk wait below
		}

		d.requestID = d.pr.RequestID
		if d.timing.RoutedAt.IsZero() {
			d.timing.RoutedAt = time.Now()
		}
		s.ddIncr("routing.decisions", []string{"model:" + d.model, "outcome:selected"})
		s.ddIncr("routing.provider_selected", []string{"provider_id:" + d.provider.ID, "model:" + d.model})

		s.logger.Info("inference request dispatched",
			"trace_id", requestIDFromContext(r.Context()),
			"request_id", d.requestID,
			"model", d.model,
			"provider_id", d.provider.ID,
			"stream", d.stream,
			"attempt", attempt+1,
		)

		s.logger.Info("dispatch_pool",
			"model", d.model,
			"ttft_deadline_ms", d.deadline.Milliseconds(),
			"speculative_at_ms", d.speculativeAt.Milliseconds(),
		)

		// ---- Speculative TTFT-aware first-chunk wait ----
		switch d.waitFirstChunk() {
		case outcomeRetry:
			continue
		case outcomeClientGone:
			return
		case outcomeAccepted:
			// Provider accepted or held preamble but hasn't produced content.
			switch d.waitAccepted() {
			case outcomeRetry:
				continue
			case outcomeClientGone:
				return
			}
		}

		break
	}

exhausted:
	if !d.committed {
		d.refundReservation()
		statusCode := d.lastErrCode
		if statusCode == 0 {
			// Distinguish capacity exhaustion (429) from genuine unavailability (503).
			// A quick capacity check tells us if providers exist but are full.
			_, capRej, _ := s.registry.QuickCapacityCheckForRequest(d.model, d.estimatedPromptTokens, d.requestedMaxTokens, registry.RequestTraits{HasTools: d.hasTools}, d.requiresVision, d.allowedProviderSerials...)
			if capRej > 0 {
				statusCode = http.StatusTooManyRequests
			} else {
				statusCode = http.StatusServiceUnavailable
			}
		}
		s.emitRequest(r.Context(), protocol.SeverityError, d.requestID,
			fmt.Sprintf("inference failed after %d attempt(s)", maxDispatchAttempts),
			map[string]any{
				"reason":      "dispatch_exhausted",
				"attempt":     maxDispatchAttempts,
				"status_code": statusCode,
				"last_error":  d.lastErr,
			})
		if s.metrics != nil {
			s.metrics.IncCounter("inference_dispatches_total", MetricLabel{"result", "failure"})
		}
		s.ddIncr("inference.dispatches", []string{"status:failure"})
		if statusCode == http.StatusTooManyRequests || statusCode == http.StatusServiceUnavailable {
			w.Header().Set("Retry-After", strconv.Itoa(s.estimateRetryAfter(d.model)))
		}
		if statusCode == http.StatusTooManyRequests {
			writeJSON(w, statusCode, errorResponse("rate_limit_exceeded",
				fmt.Sprintf("all providers at capacity after %d attempt(s): %s", maxDispatchAttempts, d.lastErr),
				withCode("rate_limit_exceeded")))
		} else {
			writeJSON(w, statusCode, errorResponse("provider_error",
				fmt.Sprintf("inference failed after %d attempt(s): %s", maxDispatchAttempts, d.lastErr)))
		}
		return
	}
	if s.metrics != nil {
		s.metrics.IncCounter("inference_dispatches_total", MetricLabel{"result", "success"})
	}
	s.ddIncr("inference.dispatches", []string{"status:success"})

	d.writeCommittedResponse()
}

func contentLatency(t *registry.RequestTiming) time.Duration {
	if t == nil || t.DispatchedAt.IsZero() || t.FirstContentAt.IsZero() {
		return 0
	}
	if d := t.FirstContentAt.Sub(t.DispatchedAt); d > 0 {
		return d
	}
	return 0
}

func adjustLatencyForPrefill(raw time.Duration, promptTokens int, prefillTPS float64) time.Duration {
	if raw <= 0 {
		return 0
	}
	if promptTokens > 0 && prefillTPS > 0 {
		raw -= time.Duration(float64(promptTokens) / prefillTPS * float64(time.Second))
	}
	if raw <= 0 {
		return 0
	}
	return raw
}

// writeCommittedResponse writes the provider attestation + timing headers, installs
// the park-before-remove settlement defer, and hands off to the streaming /
// non-streaming response writer. Extracted verbatim from the committed tail of the
// original handler.
func (d *dispatchState) writeCommittedResponse() {
	s := d.s
	w, r := d.w, d.r
	provider, pr, requestID := d.provider, d.pr, d.requestID

	if pr.Timing != nil && d.firstChunk != "" {
		if pr.Timing.FirstContentAt.IsZero() {
			pr.Timing.FirstContentAt = time.Now()
		}
		sample := adjustLatencyForPrefill(contentLatency(pr.Timing), pr.EstimatedPromptTokens, provider.PrefillTPS)
		s.registry.RecordLatency(provider.ID, sample)
	}

	// Write provider attestation headers now that we're committed.
	provider.Mu().Lock()
	pubKey := provider.PublicKey
	attested := provider.Attested
	trustLevel := provider.TrustLevel
	attestResult := provider.AttestationResult
	mdaVerified := provider.MDAVerified
	provider.Mu().Unlock()

	providerID := provider.ID
	chipName := provider.Hardware.ChipName
	machineModel := provider.Hardware.MachineModel

	if pubKey != "" {
		w.Header().Set("X-Provider-Encrypted", "true")
	}
	if pr.CacheAffinityKey != "" {
		s.registry.RecordCacheAffinity(pr.ConsumerKey, pr.Model, pr.CacheAffinityKey, provider.ID)
	}
	if attested {
		w.Header().Set("X-Provider-Attested", "true")
	} else {
		w.Header().Set("X-Provider-Attested", "false")
	}
	w.Header().Set("X-Provider-Trust-Level", string(trustLevel))
	w.Header().Set("X-Provider-Id", providerID)
	w.Header().Set("X-Provider-Chip", chipName)
	w.Header().Set("X-Provider-Model", machineModel)
	if attestResult != nil {
		w.Header().Set("X-Provider-Serial", attestResult.SerialNumber)
		if attestResult.SecureEnclaveAvailable {
			w.Header().Set("X-Provider-Secure-Enclave", "true")
		} else {
			w.Header().Set("X-Provider-Secure-Enclave", "false")
		}
	}
	if mdaVerified {
		w.Header().Set("X-Provider-Mda-Verified", "true")
	}
	// SE public key for attestation receipt verification.
	// Consumers can use this to verify SE signatures on response hashes.
	if attestResult != nil && attestResult.PublicKey != "" {
		w.Header().Set("X-Attestation-Se-Public-Key", attestResult.PublicKey)
		w.Header().Set("X-Attestation-Device-Serial", attestResult.SerialNumber)
	}

	// Latency decomposition header for observability.
	if timing := pr.Timing; timing != nil {
		type timingJSON struct {
			ParseUs    int64 `json:"parse_us"`
			ReserveUs  int64 `json:"reserve_us"`
			RouteUs    int64 `json:"route_us"`
			QueueUs    int64 `json:"queue_us"`
			EncryptUs  int64 `json:"encrypt_us"`
			DispatchUs int64 `json:"dispatch_us"`
			ProviderUs int64 `json:"provider_us"`
		}
		tj := timingJSON{}
		if !timing.ParsedAt.IsZero() {
			tj.ParseUs = timing.ParsedAt.Sub(timing.ReceivedAt).Microseconds()
		}
		if !timing.ReservedAt.IsZero() && !timing.ParsedAt.IsZero() {
			tj.ReserveUs = timing.ReservedAt.Sub(timing.ParsedAt).Microseconds()
		}
		if !timing.RoutedAt.IsZero() && !timing.ReservedAt.IsZero() {
			tj.RouteUs = timing.RoutedAt.Sub(timing.ReservedAt).Microseconds()
		}
		if !timing.QueuedAt.IsZero() && !timing.DispatchedAt.IsZero() {
			tj.QueueUs = timing.DispatchedAt.Sub(timing.QueuedAt).Microseconds()
		}
		if !timing.EncryptedAt.IsZero() && !timing.RoutedAt.IsZero() {
			tj.EncryptUs = timing.EncryptedAt.Sub(timing.RoutedAt).Microseconds()
		}
		if !timing.DispatchedAt.IsZero() && !timing.EncryptedAt.IsZero() {
			tj.DispatchUs = timing.DispatchedAt.Sub(timing.EncryptedAt).Microseconds()
		}
		if !timing.FirstChunkAt.IsZero() && !timing.DispatchedAt.IsZero() {
			tj.ProviderUs = timing.FirstChunkAt.Sub(timing.DispatchedAt).Microseconds()
		}
		if tjJSON, err := json.Marshal(tj); err == nil {
			w.Header().Set("X-Timing", string(tjJSON))
		}
	}

	// On return (disconnect/timeout/completion): free the slot, tell the
	// provider to stop, and preserve billing for a mid-stream disconnect.
	// Park BEFORE RemovePending so a racing provider terminal always finds the
	// record in pending or the holder — never neither (which would drop it and
	// mis-refund). GetPending is nil if a terminal already settled it (normal
	// completion), so nothing is parked then. Both settle paths are
	// FinalizeReservation-guarded, so the park-then-remove overlap can't double-bill.
	defer func() {
		if stale := provider.GetPending(requestID); stale != nil {
			s.holdForSettlement(stale)
		} else {
			// A terminal already claimed the pending. In every normal path the
			// reservation is finalized by now (completion billed it, the relay
			// error/timeout branches refunded it) and this is a no-op. The one
			// exception is a provider error landing in the gap between this
			// handler abandoning its channels and this defer running: that
			// terminal pushed into an unread ErrorCh and nobody settled — sweep
			// it here. Post-commit only, so it can never finalize a reservation
			// the dispatch loop still needs for a retry attempt.
			refundPr := pr
			saferun.Go(s.logger, "api.postTerminalSweep", func() {
				s.refundReservedBalance(refundPr, "post_terminal_sweep:"+requestID)
			})
		}
		provider.RemovePending(requestID) // then remove so SetProviderIdle frees the slot
		s.registry.SetProviderIdle(provider.ID)
		s.sendProviderCancel(provider, requestID)
	}()

	// The committed provider's held preamble chunks stream out first, in
	// arrival order, ahead of the content chunk that committed the dispatch.
	firstChunks := d.heldChunks
	if d.firstChunk != "" {
		firstChunks = append(firstChunks, d.firstChunk)
	}
	if d.stream {
		s.handleStreamingResponseWithFirstChunk(w, r, pr, firstChunks)
	} else {
		s.handleNonStreamingResponseWithFirstChunk(w, r, pr, firstChunks)
	}
}
