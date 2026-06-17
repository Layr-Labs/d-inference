package api

import (
	"net/http"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// noteDispatchRetry feeds the inference-error breaker + refund for a pre-commit
// provider error and, unless held boilerplate was discarded (which emits its own
// pre-content failover counter), emits the generic retry counter. This is the
// exact `if !s.noteDispatchProviderError(...) { s.ddIncr(retry) }` pattern.
func (d *dispatchState) noteDispatchRetry(provider *registry.Provider, pr *registry.PendingRequest, statusCode int, held *[]string) {
	if !d.s.noteDispatchProviderError(provider, pr, statusCode, held) {
		d.s.ddIncr("inference.dispatches", []string{"status:retry"})
	}
}

// waitFirstChunk runs the speculative TTFT-aware first-chunk wait (the former
// `firstChunkWait` labeled loop). It holds preamble chunks, commits on first
// content, extends on AcceptedCh / preamble liveness, retries invisibly on
// provider error/timeout, and launches the speculative backup race when the
// primary is slow. Returns outcomeCommitted (content / clean close), outcomeAccepted
// (cold-load or preamble liveness — proceed to waitAccepted), outcomeRetry
// (advance to the next attempt), or outcomeClientGone (context cancelled, refunded).
func (d *dispatchState) waitFirstChunk() (outcome dispatchOutcome) {
	s := d.s
	r := d.r
	provider, pr := d.provider, d.pr

	defer func() {
		switch outcome {
		case outcomeCommitted:
			d.updateRoutingOutcome(d.successRoutingOutcome())
		case outcomeRetry:
			if d.lastErrCode == http.StatusGatewayTimeout {
				d.updateRoutingOutcome(d.errorRoutingOutcome("timeout", "first_chunk_timeout", d.lastErrCode))
			} else {
				// Post-dispatch provider failure (incl. OOM/model-load): admitted but failed.
				d.updateRoutingOutcome(d.providerFailedRoutingOutcome())
			}
		case outcomeClientGone:
			d.updateRoutingOutcome(d.errorRoutingOutcome("cancelled", "client_gone", 0))
		}
	}()

	speculativeTimer := time.NewTimer(d.speculativeAt)
	deadlineTimer := time.NewTimer(d.deadline)
	d.accepted = false
	// preambleLiveness distinguishes WHY the extended first-content wait was
	// entered: a genuine AcceptedCh (cold model load — keeps the full
	// inferenceTimeout) vs a held-boilerplate liveness extension past an
	// expired TTFT deadline (zero bytes written to the client — bounded by
	// preambleContentTimeout so a role-then-stall zombie fails over).
	d.preambleLiveness = false

	for {
		select {
		case chunk, ok := <-pr.ChunkCh:
			if ok && len(d.heldChunks) < maxHeldBoilerplate && isBoilerplateChunk(chunk) {
				d.heldChunks = append(d.heldChunks, chunk)
				pr.MarkFirstChunkArrived()
				continue
			}
			speculativeTimer.Stop()
			deadlineTimer.Stop()
			if ok {
				d.firstChunk = chunk
				pr.MarkFirstChunkArrived()
				d.committed = true
			} else {
				select {
				case errMsg := <-pr.ErrorCh:
					d.excludeProviders[provider.ID] = struct{}{}
					s.cancelDispatch(provider, pr)
					d.lastErr = errMsg.Error
					d.lastErrCode = errMsg.StatusCode
					d.lastFailedVersion = failedProviderVersion(provider)
					d.noteDispatchRetry(provider, pr, errMsg.StatusCode, &d.heldChunks)
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
			speculativeTimer.Stop()
			deadlineTimer.Stop()
			d.accepted = true
			return outcomeAccepted

		case errMsg := <-pr.ErrorCh:
			speculativeTimer.Stop()
			deadlineTimer.Stop()
			d.excludeProviders[provider.ID] = struct{}{}
			s.cancelDispatch(provider, pr)
			d.lastErr = errMsg.Error
			d.lastErrCode = errMsg.StatusCode
			d.lastFailedVersion = failedProviderVersion(provider)
			s.logger.Warn("provider failed, retrying",
				"request_id", d.requestID,
				"provider_id", provider.ID,
				"attempt", d.attempt+1,
				"error", errMsg.Error,
			)
			s.emitRequest(r.Context(), protocol.SeverityWarn, d.requestID,
				"provider failed, retrying",
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

		case <-speculativeTimer.C:
			deadlineTimer.Stop()
			return d.runSpeculative()

		case <-deadlineTimer.C:
			speculativeTimer.Stop()
			if len(d.heldChunks) > 0 {
				// Preamble liveness — the provider is alive but still in its
				// pre-content phase. Fall through to the extended
				// (preambleContentTimeout) wait instead of failing the attempt.
				d.accepted = true
				d.preambleLiveness = true
				return outcomeAccepted
			}
			d.excludeProviders[provider.ID] = struct{}{}
			s.registry.RecordWarmPoolTTFTMiss(d.model, d.deadline)
			s.cancelDispatch(provider, pr)
			d.lastErr = "timeout waiting for first response"
			d.lastErrCode = http.StatusGatewayTimeout
			s.logger.Warn("provider timeout (full deadline), retrying",
				"request_id", d.requestID,
				"provider_id", provider.ID,
				"attempt", d.attempt+1,
			)
			s.emitRequest(r.Context(), protocol.SeverityWarn, d.requestID,
				"provider first-chunk timeout",
				map[string]any{
					"provider_id": provider.ID,
					"attempt":     d.attempt + 1,
					"reason":      "first_chunk_timeout",
				})
			if s.metrics != nil {
				s.metrics.IncCounter("inference_dispatches_total", MetricLabel{"result", "timeout"})
			}
			s.ddIncr("inference.dispatches", []string{"status:timeout"})
			d.provider = nil
			d.pr = nil
			return outcomeRetry

		case <-r.Context().Done():
			speculativeTimer.Stop()
			deadlineTimer.Stop()
			s.cancelDispatch(provider, pr)
			d.refundReservation()
			return outcomeClientGone
		}
	}
}

// runSpeculative is the speculativeTimer.C arm of waitFirstChunk: the primary is
// slow, so dispatch a speculative backup (unless this is a prefer request being
// served by the caller's own machine) and either keep waiting for the primary
// alone (no backup available) or race primary vs backup. Returns the same outcome
// set as waitFirstChunk.
func (d *dispatchState) runSpeculative() dispatchOutcome {
	s := d.s
	r := d.r
	provider := d.provider

	// Primary is slow. Attempt speculative backup dispatch.
	s.ddIncr("inference.speculative_dispatch", []string{"model:" + d.model})
	s.registry.RecordWarmPoolSpeculativeStarted(d.model)

	var backupProvider *registry.Provider
	var backupPR *registry.PendingRequest

	// Do NOT speculatively race a paid PUBLIC backup against a prefer
	// request that is being served by the caller's OWN machine: the user
	// opted into "prefer my machine (free)", so a slow owned machine must
	// be waited on, not raced (and billed) by the public fleet. (Exclusive
	// self-route is already safe — its backup selection is owned-only and
	// returns nil when there's no other owned machine.) When the prefer
	// primary is itself a public provider (the owner owns nothing / fell
	// back), normal speculative behaviour applies.
	skipBackup := false
	if d.policy.prefer {
		provider.Mu().Lock()
		skipBackup = d.policy.ownerAccountID != "" && provider.AccountID == d.policy.ownerAccountID
		provider.Mu().Unlock()
	}

	if !skipBackup {
		backupExclude := make(map[string]struct{}, len(d.excludeProviders)+1)
		for id := range d.excludeProviders {
			backupExclude[id] = struct{}{}
		}
		backupExclude[provider.ID] = struct{}{}

		backupProvider, backupPR, _, _, _ = s.dispatchOneProvider(
			r, d.model, d.publicModel, d.rawBody, d.consumerKey, d.consumerLocation, d.reservedMicroUSD,
			d.estimatedPromptTokens, d.requestedMaxTokens, d.tokenAdmission, d.requiresVision,
			d.traits(),
			d.allowedProviderSerials, d.isResponsesAPI, d.policy,
			&registry.RequestTiming{ReceivedAt: d.timing.ReceivedAt},
			d.serviceReservation,
			d.cacheAffinityKey,
			backupExclude,
			d.attempt,
		)
	}

	if backupProvider == nil {
		// No backup available. Keep waiting for primary with remaining deadline.
		s.logger.Info("speculative_dispatch_no_backup",
			"request_id", d.requestID,
			"primary_provider", provider.ID,
		)
		return d.waitNoBackup()
	}
	// Backup dispatched — race primary vs backup.
	s.logger.Info("speculative_dispatch",
		"request_id", d.requestID,
		"primary_provider", provider.ID,
		"backup_provider", backupProvider.ID,
		"ttft_deadline_ms", d.deadline.Milliseconds(),
		"speculative_at_ms", d.speculativeAt.Milliseconds(),
	)
	return d.runRace(backupProvider, backupPR)
}

// waitNoBackup is the speculative-no-backup branch (`noBackupWait`): keep waiting
// for the primary alone with the remaining deadline. d.provider / d.pr are the primary.
func (d *dispatchState) waitNoBackup() dispatchOutcome {
	s := d.s
	r := d.r
	provider, pr := d.provider, d.pr

	remainingDeadline := time.NewTimer(d.deadline - d.speculativeAt)
	for {
		select {
		case chunk, ok := <-pr.ChunkCh:
			if ok && len(d.heldChunks) < maxHeldBoilerplate && isBoilerplateChunk(chunk) {
				d.heldChunks = append(d.heldChunks, chunk)
				pr.MarkFirstChunkArrived()
				continue
			}
			remainingDeadline.Stop()
			if ok {
				d.firstChunk = chunk
				pr.MarkFirstChunkArrived()
				d.committed = true
			} else {
				select {
				case errMsg := <-pr.ErrorCh:
					d.excludeProviders[provider.ID] = struct{}{}
					s.cancelDispatch(provider, pr)
					d.lastErr = errMsg.Error
					d.lastErrCode = errMsg.StatusCode
					d.lastFailedVersion = failedProviderVersion(provider)
					d.noteDispatchRetry(provider, pr, errMsg.StatusCode, &d.heldChunks)
					d.provider = nil
					d.pr = nil
					return outcomeRetry
				default:
					d.committed = true
				}
			}
			return outcomeCommitted
		case <-pr.AcceptedCh:
			remainingDeadline.Stop()
			d.accepted = true
			return outcomeAccepted
		case errMsg := <-pr.ErrorCh:
			remainingDeadline.Stop()
			d.excludeProviders[provider.ID] = struct{}{}
			s.cancelDispatch(provider, pr)
			d.lastErr = errMsg.Error
			d.lastErrCode = errMsg.StatusCode
			d.lastFailedVersion = failedProviderVersion(provider)
			if s.metrics != nil {
				s.metrics.IncCounter("inference_dispatches_total", MetricLabel{"result", "retry"})
			}
			d.noteDispatchRetry(provider, pr, errMsg.StatusCode, &d.heldChunks)
			d.provider = nil
			d.pr = nil
			return outcomeRetry
		case <-remainingDeadline.C:
			if len(d.heldChunks) > 0 {
				// Liveness: the provider already produced its preamble —
				// vision prefill / template render may legitimately
				// exceed the TTFT deadline. Fall through to the
				// extended (preambleContentTimeout) wait for first
				// content, with ErrorCh still armed for retry.
				d.accepted = true
				d.preambleLiveness = true
				return outcomeAccepted
			}
			d.excludeProviders[provider.ID] = struct{}{}
			s.registry.RecordWarmPoolTTFTMiss(d.model, d.deadline)
			s.cancelDispatch(provider, pr)
			d.lastErr = "timeout waiting for first response"
			d.lastErrCode = http.StatusGatewayTimeout
			s.logger.Warn("provider timeout (no backup), retrying",
				"request_id", d.requestID,
				"provider_id", provider.ID,
				"attempt", d.attempt+1,
			)
			s.emitRequest(r.Context(), protocol.SeverityWarn, d.requestID,
				"provider first-chunk timeout",
				map[string]any{
					"provider_id": provider.ID,
					"attempt":     d.attempt + 1,
					"reason":      "first_chunk_timeout",
				})
			if s.metrics != nil {
				s.metrics.IncCounter("inference_dispatches_total", MetricLabel{"result", "timeout"})
			}
			s.ddIncr("inference.dispatches", []string{"status:timeout"})
			d.provider = nil
			d.pr = nil
			return outcomeRetry
		case <-r.Context().Done():
			remainingDeadline.Stop()
			s.cancelDispatch(provider, pr)
			d.refundReservation()
			return outcomeClientGone
		}
	}
}
