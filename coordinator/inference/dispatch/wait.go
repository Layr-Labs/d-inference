package dispatch

import (
	"net/http"
	"time"

	attemptpolicy "github.com/eigeninference/d-inference/coordinator/inference/attempt"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/telemetry/metrics"
)

// waitFirstChunk runs the speculative TTFT-aware first-chunk wait (the former
// `firstChunkWait` labeled loop). It holds preamble chunks, commits on first
// content, ignores AcceptedCh for race/timer decisions, may proceed to
// waitAccepted only for legacy preamble liveness, retries invisibly on provider
// error/timeout, and launches the speculative backup race when the primary is
// slow. Returns outcomeCommitted (content / clean close), outcomeAccepted
// (legacy preamble liveness — proceed to waitAccepted), outcomeRetry
// (advance to the next attempt), or outcomeClientGone (context cancelled, refunded).
func (d *execution) waitFirstChunk() (outcome dispatchOutcome) {
	s := d.s
	r := d.r
	provider, pr := d.provider, d.pr
	captured := routingAttempt(provider, pr, pr.RequestID, pr.Attempt)

	defer func() {
		target := d.currentOrCapturedRoutingAttempt(captured)
		switch outcome {
		case outcomeCommitted:
			d.updateRoutingOutcomeForAttempt(target, d.successRoutingOutcomeFor(target.pending))
		case outcomeRetry:
			// A 504 here is a coordinator-synthesized first-chunk timeout
			// unless it carries a KNOWN typed 504 cause (safety_deadline /
			// backpressure_timeout) — those are real provider terminals and
			// keep their provider-error route class and attempt usage.
			// setLastError clears the cause for synthetic timeouts (so the
			// discriminator cannot go stale), and an UNKNOWN cause value
			// stays on this legacy timeout path, mirroring
			// classifyTerminalCause's unknown→legacy rule for mixed-version
			// rollouts.
			if d.lastErrCode == http.StatusGatewayTimeout && !attemptpolicy.IsTypedTimeout504Cause(d.lastErrTerminalCause) {
				d.updateRoutingOutcomeForAttempt(target, d.errorRoutingOutcomeFor(target.pending, "timeout", "first_chunk_timeout", d.lastErrCode))
			} else {
				// Post-dispatch provider failure (incl. OOM/model-load): admitted but failed.
				d.updateRoutingOutcomeForAttempt(target, d.providerFailedRoutingOutcomeFor(target.pending))
			}
		case outcomeClientGone:
			d.emitClientGone(phaseBeforeFirstToken)
			d.updateRoutingOutcomeForAttempt(target, d.errorRoutingOutcomeFor(target.pending, "cancelled", "client_gone", 0))
		}
	}()

	deadlineWait := d.firstTokenWait(d.deadline)
	speculativeTimer := time.NewTimer(d.firstTokenSpeculativeWait())
	deadlineTimer := time.NewTimer(deadlineWait)
	// Routing v2 W2: the probe round may deliver ONE refined (strictly
	// earlier) absolute speculative launch instant. Read through a local so
	// the arm disarms itself after its single use; a nil channel (no probe
	// round) never fires.
	hedgeAdvance := d.hedgeAdvanceCh
	// preambleLiveness records that held boilerplate earned a legacy bounded
	// extension. AcceptedCh never earns or resets a content wait.
	// A preamble-then-stall with leftover budget is still bounded by
	// preambleContentTimeout so a role-then-stall zombie fails over.
	d.preambleLiveness = false

	for {
		select {
		case chunk, ok := <-pr.ChunkCh:
			if ok && holdPreContentBoilerplate(pr, chunk, &d.heldChunks) {
				if d.firstTokenSpeculativeWait() <= 0 {
					speculativeTimer.Stop()
					deadlineTimer.Stop()
					return d.runSpeculative()
				}
				continue
			}
			speculativeTimer.Stop()
			deadlineTimer.Stop()
			if ok {
				d.commitFirstContent(pr, chunk.Data)
				d.committed = true
			} else {
				select {
				case errMsg := <-pr.ErrorCh:
					d.excludeProviders[provider.ID] = struct{}{}
					s.deps.Attempts().CancelAfterTerminal(provider, pr)
					d.setLastInferenceError(provider, errMsg)
					d.lastFailedVersion = failedProviderVersion(provider)
					d.noteDispatchRetry(provider, pr, errMsg.StatusCode, errMsg.Error, errMsg.ErrorReason, errMsg.TerminalCause, &d.heldChunks, errMsg.CoordinatorCause)
					d.provider = nil
					d.pr = nil
					return outcomeRetry
				default:
					// Closed without error — commit (held chunks only is
					// fine: a preamble-then-complete stream is empty output).
					d.committed = true
				}
			}
			return outcomeCommitted

		case <-pr.AcceptedCh:
			// Acceptance is not content and must not suppress either the
			// speculative launch point or the absolute first-content timer.
			continue

		case errMsg := <-pr.ErrorCh:
			speculativeTimer.Stop()
			deadlineTimer.Stop()
			if d.commitReadyFirstContent(pr, &d.heldChunks, errMsg) {
				return outcomeCommitted
			}
			d.excludeProviders[provider.ID] = struct{}{}
			s.deps.Attempts().CancelAfterTerminal(provider, pr)
			d.setLastInferenceError(provider, errMsg)
			d.lastFailedVersion = failedProviderVersion(provider)
			s.deps.Logger().Warn("provider failed, retrying",
				"request_id", d.requestID,
				"provider_id", provider.ID,
				"attempt", d.attempt+1,
				"failure_code", errMsg.FailureCode,
			)
			s.deps.Observer.Event(r.Context(), protocol.SeverityWarn, d.requestID,
				"provider failed, retrying",
				map[string]any{
					"provider_id": provider.ID,
					"attempt":     d.attempt + 1,
					"reason":      "provider_error",
					"status_code": errMsg.StatusCode,
				})
			if s.deps.Metrics() != nil {
				s.deps.Metrics().IncCounter("inference_dispatches_total", metrics.Label{Name: "result", Value: "retry"})
			}
			d.noteDispatchRetry(provider, pr, errMsg.StatusCode, errMsg.Error, errMsg.ErrorReason, errMsg.TerminalCause, &d.heldChunks, errMsg.CoordinatorCause)
			d.provider = nil
			d.pr = nil
			return outcomeRetry

		case at := <-hedgeAdvance:
			// One-shot re-arm of the speculative timer to the probe round's
			// refined launch instant. Guards, in order: only once (the local
			// disarms), only with the absolute clock stamped (mirrors
			// first_token_clock.go invariant 5), only strictly EARLIER than
			// the armed point, and never after the timer fired — Stop()
			// reports whether the timer was still pending; a spent fire stays
			// buffered in C for its own arm and must not be re-armed over.
			// Never past the deadline by construction: hedgeLaunchAt's
			// ceiling is deadline/2. speculativeAt is updated so every
			// downstream remaining-window computation, the launch-now check
			// above, and telemetry agree with the re-armed timer; without a
			// delivered value it stays the 50% default — exact legacy timing.
			hedgeAdvance = nil
			receivedAt := TimingReceivedAt(d.timing)
			if receivedAt.IsZero() || !at.Before(receivedAt.Add(d.speculativeAt)) {
				continue
			}
			if !speculativeTimer.Stop() {
				continue
			}
			d.speculativeAt = at.Sub(receivedAt)
			if d.speculativeAt < 0 {
				d.speculativeAt = 0
			}
			speculativeTimer.Reset(d.firstTokenSpeculativeWait())
			continue

		case <-speculativeTimer.C:
			if pr.FirstContentIngressArrivedByDeadline() {
				if d.onSpeculativeDeferral != nil {
					d.onSpeculativeDeferral()
				}
				continue
			}
			deadlineTimer.Stop()
			return d.runSpeculative()

		case <-deadlineTimer.C:
			speculativeTimer.Stop()
			if chunk, ok := drainReadyFirstContent(pr, &d.heldChunks); ok {
				d.commitFirstContent(pr, chunk.Data)
				d.committed = true
				return outcomeCommitted
			}
			if pr.FirstContentIngressArrivedByDeadline() {
				continue
			}
			if len(d.heldChunks) > 0 && d.canExtendPreambleLiveness() {
				// Preamble liveness — the provider is alive but still in its
				// pre-content phase. Fall through to waitAccepted, still
				// bounded by leftover request-absolute first-token budget.
				d.preambleLiveness = true
				return outcomeAccepted
			}
			if !s.deps.Attempts().CancelForFirstContentTimeout(provider, pr) {
				continue
			}
			d.excludeProviders[provider.ID] = struct{}{}
			s.deps.Registry().RecordWarmPoolTTFTMiss(d.model, d.deadline)
			if providerAttemptAttributableStall(pr, d.deadline) {
				s.deps.Attempts().Error(provider.ID, pr, http.StatusGatewayTimeout, "", "", "")
			}
			d.setLastError("timeout waiting for first response", http.StatusGatewayTimeout)
			s.deps.Logger().Warn("provider timeout (full deadline), retrying",
				"request_id", d.requestID,
				"provider_id", provider.ID,
				"attempt", d.attempt+1,
			)
			s.deps.Observer.Event(r.Context(), protocol.SeverityWarn, d.requestID,
				"provider first-chunk timeout",
				map[string]any{
					"provider_id": provider.ID,
					"attempt":     d.attempt + 1,
					"reason":      "first_chunk_timeout",
				})
			if s.deps.Metrics() != nil {
				s.deps.Metrics().IncCounter("inference_dispatches_total", metrics.Label{Name: "result", Value: "timeout"})
			}
			s.deps.Counters.Incr("inference.dispatches", []string{"status:timeout"})
			d.provider = nil
			d.pr = nil
			return outcomeRetry

		case <-r.Context().Done():
			speculativeTimer.Stop()
			deadlineTimer.Stop()
			s.deps.Attempts().Cancel(provider, pr, attemptpolicy.CancelCauseClientGonePre)
			d.refundReservation()
			return outcomeClientGone
		}
	}
}

// waitNoBackup is the speculative-no-backup branch (`noBackupWait`): keep waiting
// for the primary alone with the remaining deadline. d.provider / d.pr are the primary.
func (d *execution) waitNoBackup() dispatchOutcome {
	s := d.s
	r := d.r
	provider, pr := d.provider, d.pr

	remainingDeadline := time.NewTimer(d.firstTokenWait(d.deadline - d.speculativeAt))
	for {
		select {
		case chunk, ok := <-pr.ChunkCh:
			if ok && holdPreContentBoilerplate(pr, chunk, &d.heldChunks) {
				continue
			}
			remainingDeadline.Stop()
			if ok {
				d.commitFirstContent(pr, chunk.Data)
				d.committed = true
			} else {
				select {
				case errMsg := <-pr.ErrorCh:
					d.excludeProviders[provider.ID] = struct{}{}
					s.deps.Attempts().CancelAfterTerminal(provider, pr)
					d.setLastInferenceError(provider, errMsg)
					d.lastFailedVersion = failedProviderVersion(provider)
					d.noteDispatchRetry(provider, pr, errMsg.StatusCode, errMsg.Error, errMsg.ErrorReason, errMsg.TerminalCause, &d.heldChunks, errMsg.CoordinatorCause)
					d.provider = nil
					d.pr = nil
					return outcomeRetry
				default:
					d.committed = true
				}
			}
			return outcomeCommitted
		case <-pr.AcceptedCh:
			continue
		case errMsg := <-pr.ErrorCh:
			remainingDeadline.Stop()
			if d.commitReadyFirstContent(pr, &d.heldChunks, errMsg) {
				return outcomeCommitted
			}
			d.excludeProviders[provider.ID] = struct{}{}
			s.deps.Attempts().CancelAfterTerminal(provider, pr)
			d.setLastInferenceError(provider, errMsg)
			d.lastFailedVersion = failedProviderVersion(provider)
			if s.deps.Metrics() != nil {
				s.deps.Metrics().IncCounter("inference_dispatches_total", metrics.Label{Name: "result", Value: "retry"})
			}
			d.noteDispatchRetry(provider, pr, errMsg.StatusCode, errMsg.Error, errMsg.ErrorReason, errMsg.TerminalCause, &d.heldChunks, errMsg.CoordinatorCause)
			d.provider = nil
			d.pr = nil
			return outcomeRetry
		case <-remainingDeadline.C:
			if chunk, ok := drainReadyFirstContent(pr, &d.heldChunks); ok {
				d.commitFirstContent(pr, chunk.Data)
				d.committed = true
				return outcomeCommitted
			}
			if pr.FirstContentIngressArrivedByDeadline() {
				continue
			}
			if len(d.heldChunks) > 0 && d.canExtendPreambleLiveness() {
				// Liveness: the provider already produced its preamble.
				// Fall through to waitAccepted, still bounded by leftover
				// request-absolute first-token budget.
				d.preambleLiveness = true
				return outcomeAccepted
			}
			if !s.deps.Attempts().CancelForFirstContentTimeout(provider, pr) {
				continue
			}
			d.excludeProviders[provider.ID] = struct{}{}
			s.deps.Registry().RecordWarmPoolTTFTMiss(d.model, d.deadline)
			if providerAttemptAttributableStall(pr, d.deadline) {
				s.deps.Attempts().Error(provider.ID, pr, http.StatusGatewayTimeout, "", "", "")
			}
			d.setLastError("timeout waiting for first response", http.StatusGatewayTimeout)
			s.deps.Logger().Warn("provider timeout (no backup), retrying",
				"request_id", d.requestID,
				"provider_id", provider.ID,
				"attempt", d.attempt+1,
			)
			s.deps.Observer.Event(r.Context(), protocol.SeverityWarn, d.requestID,
				"provider first-chunk timeout",
				map[string]any{
					"provider_id": provider.ID,
					"attempt":     d.attempt + 1,
					"reason":      "first_chunk_timeout",
				})
			if s.deps.Metrics() != nil {
				s.deps.Metrics().IncCounter("inference_dispatches_total", metrics.Label{Name: "result", Value: "timeout"})
			}
			s.deps.Counters.Incr("inference.dispatches", []string{"status:timeout"})
			d.provider = nil
			d.pr = nil
			return outcomeRetry
		case <-r.Context().Done():
			remainingDeadline.Stop()
			s.deps.Attempts().Cancel(provider, pr, attemptpolicy.CancelCauseClientGonePre)
			d.refundReservation()
			return outcomeClientGone
		}
	}
}

// waitAccepted runs the post-accept wait for first content (the former
// `acceptedWait` loop). It is entered when the committed provider accepted or held
// preamble but hasn't produced content yet. Accept is not a completion token:
// the request-absolute first-token clock keeps running. preambleLiveness still
// caps the wait at preambleContentTimeout so a role-then-stall zombie fails
// over instead of pinning, but that cap cannot exceed leftover SLA.
func (d *execution) waitAccepted() (outcome dispatchOutcome) {
	s := d.s
	r := d.r
	provider, pr := d.provider, d.pr
	captured := routingAttempt(provider, pr, pr.RequestID, pr.Attempt)

	defer func() {
		target := d.currentOrCapturedRoutingAttempt(captured)
		switch outcome {
		case outcomeCommitted:
			d.updateRoutingOutcomeForAttempt(target, d.successRoutingOutcomeFor(target.pending))
		case outcomeRetry:
			// Synthetic-timeout 504s unless a KNOWN typed 504 cause — a typed
			// provider 504 keeps its provider-error class + usage; unknown
			// causes stay legacy (see waitFirstChunk).
			if d.lastErrCode == http.StatusGatewayTimeout && !attemptpolicy.IsTypedTimeout504Cause(d.lastErrTerminalCause) {
				if d.preambleLiveness {
					d.updateRoutingOutcomeForAttempt(target, d.errorRoutingOutcomeFor(target.pending, "timeout", "preamble_liveness_timeout", d.lastErrCode))
				} else {
					d.updateRoutingOutcomeForAttempt(target, d.errorRoutingOutcomeFor(target.pending, "timeout", "accepted_timeout", d.lastErrCode))
				}
			} else {
				// Post-dispatch provider failure (incl. OOM/model-load): admitted but failed.
				d.updateRoutingOutcomeForAttempt(target, d.providerFailedRoutingOutcomeFor(target.pending))
			}
		case outcomeClientGone:
			d.emitClientGone(phaseBeforeFirstToken)
			d.updateRoutingOutcomeForAttempt(target, d.errorRoutingOutcomeFor(target.pending, "cancelled", "client_gone", 0))
		}
	}()

	firstContentBudget := inferenceTimeout
	if d.preambleLiveness {
		firstContentBudget = preambleContentTimeout
	}
	if remaining, ok := d.firstTokenRemaining(); ok && remaining < firstContentBudget {
		firstContentBudget = remaining
	}
	chunkTimer := time.NewTimer(firstContentBudget)
	for {
		select {
		case chunk, ok := <-pr.ChunkCh:
			if ok && holdPreContentBoilerplate(pr, chunk, &d.heldChunks) {
				continue
			}
			chunkTimer.Stop()
			if ok {
				d.commitFirstContent(pr, chunk.Data)
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
					s.deps.Attempts().CancelAfterTerminal(provider, pr)
					d.setLastInferenceError(provider, errMsg)
					d.lastFailedVersion = failedProviderVersion(provider)
					s.deps.Logger().Warn("provider failed after accepting request, retrying",
						"request_id", d.requestID,
						"provider_id", provider.ID,
						"attempt", d.attempt+1,
						"failure_code", errMsg.FailureCode,
					)
					s.deps.Observer.Event(r.Context(), protocol.SeverityWarn, d.requestID,
						"provider failed after accepting request, retrying",
						map[string]any{
							"provider_id": provider.ID,
							"attempt":     d.attempt + 1,
							"reason":      "provider_error",
							"status_code": errMsg.StatusCode,
						})
					if s.deps.Metrics() != nil {
						s.deps.Metrics().IncCounter("inference_dispatches_total", metrics.Label{Name: "result", Value: "retry"})
					}
					d.noteDispatchRetry(provider, pr, errMsg.StatusCode, errMsg.Error, errMsg.ErrorReason, errMsg.TerminalCause, &d.heldChunks, errMsg.CoordinatorCause)
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
			if d.commitReadyFirstContent(pr, &d.heldChunks, errMsg) {
				return outcomeCommitted
			}
			d.excludeProviders[provider.ID] = struct{}{}
			s.deps.Attempts().CancelAfterTerminal(provider, pr)
			d.setLastInferenceError(provider, errMsg)
			d.lastFailedVersion = failedProviderVersion(provider)
			s.deps.Logger().Warn("provider failed after accepting request, retrying",
				"request_id", d.requestID,
				"provider_id", provider.ID,
				"attempt", d.attempt+1,
				"failure_code", errMsg.FailureCode,
			)
			s.deps.Observer.Event(r.Context(), protocol.SeverityWarn, d.requestID,
				"provider failed after accepting request, retrying",
				map[string]any{
					"provider_id": provider.ID,
					"attempt":     d.attempt + 1,
					"reason":      "provider_error",
					"status_code": errMsg.StatusCode,
				})
			if s.deps.Metrics() != nil {
				s.deps.Metrics().IncCounter("inference_dispatches_total", metrics.Label{Name: "result", Value: "retry"})
			}
			d.noteDispatchRetry(provider, pr, errMsg.StatusCode, errMsg.Error, errMsg.ErrorReason, errMsg.TerminalCause, &d.heldChunks, errMsg.CoordinatorCause)
			d.provider = nil
			d.pr = nil
			return outcomeRetry
		case <-chunkTimer.C:
			if chunk, ok := drainReadyFirstContent(pr, &d.heldChunks); ok {
				d.commitFirstContent(pr, chunk.Data)
				d.committed = true
				return outcomeCommitted
			}
			if pr.FirstContentIngressArrivedByDeadline() {
				continue
			}
			if !s.deps.Attempts().CancelForFirstContentTimeout(provider, pr) {
				continue
			}
			d.excludeProviders[provider.ID] = struct{}{}
			s.deps.Registry().RecordWarmPoolTTFTMiss(d.model, firstContentBudget)
			// Accepted-then-silent (or preamble-then-stall) feeds the
			// breaker so a provider that repeatedly acks and stalls enters
			// cooldown — but ONLY when the provider was actually granted a
			// provider-attributable window. A budget capped short by the
			// request-absolute first-token clock is OUR deadline (queueing,
			// admission), not provider sickness.
			if providerAttemptAttributableStall(pr, firstContentBudget) {
				s.deps.Attempts().Error(provider.ID, pr, http.StatusGatewayTimeout, "", "", "")
			}
			d.setLastError("provider accepted but timed out before first chunk", http.StatusGatewayTimeout)
			if d.preambleLiveness {
				d.setLastError("provider sent preamble but stalled before first content", http.StatusGatewayTimeout)
			}
			s.deps.Logger().Warn("provider timed out after accepting request, retrying",
				"request_id", d.requestID,
				"provider_id", provider.ID,
				"attempt", d.attempt+1,
				"preamble_liveness", d.preambleLiveness,
			)
			s.deps.Observer.Event(r.Context(), protocol.SeverityWarn, d.requestID,
				"provider accepted timeout",
				map[string]any{
					"provider_id": provider.ID,
					"attempt":     d.attempt + 1,
					"reason":      "accepted_timeout",
				})
			if s.deps.Metrics() != nil {
				s.deps.Metrics().IncCounter("inference_dispatches_total", metrics.Label{Name: "result", Value: "timeout"})
			}
			s.deps.Counters.Incr("inference.dispatches", []string{"status:timeout"})
			d.provider = nil
			d.pr = nil
			return outcomeRetry
		case <-r.Context().Done():
			s.deps.Attempts().Cancel(provider, pr, attemptpolicy.CancelCauseClientGonePre)
			d.refundReservation()
			return outcomeClientGone
		}
	}
}
