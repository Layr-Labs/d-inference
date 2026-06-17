package api

import (
	"net/http"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

// runRace is the speculative `race` loop: primary (d.provider/d.pr) vs backup,
// first CONTENT chunk wins; the loser is cancelled. Preamble from each racer is
// buffered separately (held chunks must never mix providers). On a racer error the
// surviving racer is waited on via a sub-loop. Returns the waitFirstChunk outcome
// set; on a backup win d.provider/d.pr/d.requestID/d.heldChunks are swapped to the backup.
func (d *dispatchState) runRace(backupProvider *registry.Provider, backupPR *registry.PendingRequest) dispatchOutcome {
	s := d.s
	r := d.r
	provider, pr := d.provider, d.pr

	raceDeadline := time.NewTimer(d.deadline - d.speculativeAt)
	// One-shot extension: when the race deadline expires but a racer
	// has shown liveness (preamble received), the race continues for
	// the full inference window instead of failing the request.
	raceExtended := false
	// Preamble chunks from the backup are buffered separately —
	// held chunks must never mix providers.
	var backupHeld []string

	for {
		select {
		case chunk, ok := <-pr.ChunkCh:
			if ok && len(d.heldChunks) < maxHeldBoilerplate && isBoilerplateChunk(chunk) {
				// Preamble only — the primary hasn't proven it can
				// generate; keep the backup racing for first content.
				d.heldChunks = append(d.heldChunks, chunk)
				pr.MarkFirstChunkArrived()
				continue
			}
			// Primary wins!
			raceDeadline.Stop()
			s.cancelDispatch(backupProvider, backupPR)
			if ok {
				d.firstChunk = chunk
				pr.MarkFirstChunkArrived()
				d.committed = true
			} else {
				select {
				case errMsg := <-pr.ErrorCh:
					// Primary failed but we already cancelled backup.
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

		case chunk, ok := <-backupPR.ChunkCh:
			if ok && len(backupHeld) < maxHeldBoilerplate && isBoilerplateChunk(chunk) {
				// Backup preamble doesn't win the race — first CONTENT does.
				backupHeld = append(backupHeld, chunk)
				backupPR.MarkFirstChunkArrived()
				continue
			}
			// Backup wins!
			raceDeadline.Stop()
			s.cancelDispatch(provider, pr)
			s.ddIncr("inference.speculative_win", []string{"model:" + d.model})
			s.registry.RecordWarmPoolSpeculativeWon(d.model)
			if ok {
				d.provider = backupProvider
				d.pr = backupPR
				d.requestID = d.pr.RequestID
				d.heldChunks = backupHeld
				d.firstChunk = chunk
				d.pr.MarkFirstChunkArrived()
				d.committed = true
			} else {
				select {
				case errMsg := <-backupPR.ErrorCh:
					// Backup failed too. Keep primary context for retry.
					d.excludeProviders[backupProvider.ID] = struct{}{}
					d.lastFailedVersion = failedProviderVersion(backupProvider)
					s.noteDispatchProviderError(backupProvider, backupPR, errMsg.StatusCode, &backupHeld)
					// Wait remaining deadline for primary.
					return d.raceBackupChunkClosedWaitPrimary(provider, pr)
				default:
					// Backup channel closed with no error — treat as committed.
					s.cancelDispatch(provider, pr)
					d.provider = backupProvider
					d.pr = backupPR
					d.requestID = d.pr.RequestID
					d.heldChunks = backupHeld
					d.committed = true
				}
			}
			return outcomeCommitted

		case <-pr.AcceptedCh:
			// Primary accepted (model reload). Cancel backup, extend deadline.
			raceDeadline.Stop()
			s.cancelDispatch(backupProvider, backupPR)
			d.accepted = true
			return outcomeAccepted

		case <-backupPR.AcceptedCh:
			// Backup accepted (model reload). Cancel primary, extend deadline.
			raceDeadline.Stop()
			s.cancelDispatch(provider, pr)
			d.provider = backupProvider
			d.pr = backupPR
			d.requestID = d.pr.RequestID
			d.heldChunks = backupHeld
			d.accepted = true
			return outcomeAccepted

		case errMsg := <-pr.ErrorCh:
			// Primary failed. Keep waiting for backup.
			raceDeadline.Stop()
			d.excludeProviders[provider.ID] = struct{}{}
			s.cancelDispatch(provider, pr)
			d.lastFailedVersion = failedProviderVersion(provider)
			s.noteDispatchProviderError(provider, pr, errMsg.StatusCode, &d.heldChunks)
			return d.racePrimaryFailedWaitBackup(backupProvider, backupPR, backupHeld)

		case errMsg := <-backupPR.ErrorCh:
			// Backup failed. Keep waiting for primary.
			raceDeadline.Stop()
			d.excludeProviders[backupProvider.ID] = struct{}{}
			s.cancelDispatch(backupProvider, backupPR)
			d.lastFailedVersion = failedProviderVersion(backupProvider)
			s.noteDispatchProviderError(backupProvider, backupPR, errMsg.StatusCode, &backupHeld)
			return d.raceBackupErrWaitPrimary(provider, pr)

		case <-raceDeadline.C:
			if !raceExtended && (len(d.heldChunks) > 0 || len(backupHeld) > 0) {
				// Liveness from at least one racer: don't fail at the
				// TTFT deadline — extend once by the preamble-to-content
				// budget (zero bytes have reached the client; a genuine
				// cold load would have signalled AcceptedCh) and keep both
				// racing for first content, with both error channels still
				// armed for retry.
				raceExtended = true
				raceDeadline = time.NewTimer(preambleContentTimeout)
				continue
			}
			// Both missed deadline. A racer that held preamble (role
			// then stall) is a 504-shaped sickness — feed the breaker
			// before cancelling, mirroring the single-provider
			// acceptedWait timeout path so a stalling provider/model
			// (shape-keyed) trips its cooldown.
			if len(d.heldChunks) > 0 {
				s.noteInferenceError(provider.ID, pr, http.StatusGatewayTimeout)
			}
			if len(backupHeld) > 0 {
				s.noteInferenceError(backupProvider.ID, backupPR, http.StatusGatewayTimeout)
			}
			s.cancelDispatch(provider, pr)
			s.registry.RecordWarmPoolTTFTMiss(d.model, d.deadline)
			s.cancelDispatch(backupProvider, backupPR)
			d.excludeProviders[provider.ID] = struct{}{}
			d.excludeProviders[backupProvider.ID] = struct{}{}
			d.lastErr = "timeout waiting for first response (both providers)"
			d.lastErrCode = http.StatusGatewayTimeout
			if s.metrics != nil {
				s.metrics.IncCounter("inference_dispatches_total", MetricLabel{"result", "timeout"})
			}
			s.ddIncr("inference.dispatches", []string{"status:timeout"})
			d.provider = nil
			d.pr = nil
			return outcomeRetry

		case <-r.Context().Done():
			raceDeadline.Stop()
			s.cancelDispatch(provider, pr)
			s.cancelDispatch(backupProvider, backupPR)
			d.refundReservation()
			return outcomeClientGone
		}
	}
}

// raceBackupChunkClosedWaitPrimary handles the race sub-case where the backup's
// ChunkCh closed with an error (already recorded by the caller): wait the
// remaining deadline for the primary. This is the former `backupFailedPrimaryWait`
// loop. d.provider/d.pr remain the primary throughout (the backup already lost).
func (d *dispatchState) raceBackupChunkClosedWaitPrimary(provider *registry.Provider, pr *registry.PendingRequest) dispatchOutcome {
	s := d.s
	r := d.r
	remainingPrimary := time.NewTimer(d.deadline - d.speculativeAt)
	for {
		select {
		case chunk, ok := <-pr.ChunkCh:
			if ok && len(d.heldChunks) < maxHeldBoilerplate && isBoilerplateChunk(chunk) {
				d.heldChunks = append(d.heldChunks, chunk)
				pr.MarkFirstChunkArrived()
				continue
			}
			remainingPrimary.Stop()
			if ok {
				d.firstChunk = chunk
				pr.MarkFirstChunkArrived()
				d.committed = true
			} else {
				select {
				case errMsg2 := <-pr.ErrorCh:
					d.excludeProviders[provider.ID] = struct{}{}
					s.cancelDispatch(provider, pr)
					d.lastErr = errMsg2.Error
					d.lastErrCode = errMsg2.StatusCode
					d.lastFailedVersion = failedProviderVersion(provider)
					d.noteDispatchRetry(provider, pr, errMsg2.StatusCode, &d.heldChunks)
					d.provider = nil
					d.pr = nil
					return outcomeRetry
				default:
					d.committed = true
				}
			}
			return outcomeCommitted
		case <-pr.AcceptedCh:
			remainingPrimary.Stop()
			d.accepted = true
			return outcomeAccepted
		case errMsg2 := <-pr.ErrorCh:
			// Defensive: both ErrorCh senders currently send before
			// closing ChunkCh (the closed-ChunkCh check above catches
			// them), but a direct arm keeps this loop correct if that
			// ordering ever changes — mirroring its sibling wait loops.
			remainingPrimary.Stop()
			d.excludeProviders[provider.ID] = struct{}{}
			s.cancelDispatch(provider, pr)
			d.lastErr = errMsg2.Error
			d.lastErrCode = errMsg2.StatusCode
			d.lastFailedVersion = failedProviderVersion(provider)
			d.noteDispatchRetry(provider, pr, errMsg2.StatusCode, &d.heldChunks)
			d.provider = nil
			d.pr = nil
			return outcomeRetry
		case <-remainingPrimary.C:
			if len(d.heldChunks) > 0 {
				// Primary preamble liveness — extend to the
				// preamble-to-content budget instead of failing.
				d.accepted = true
				d.preambleLiveness = true
				return outcomeAccepted
			}
			// The PRIMARY timed out here (the backup's earlier error
			// is already recorded); report the timeout, not the
			// backup's stale error text.
			d.excludeProviders[provider.ID] = struct{}{}
			s.registry.RecordWarmPoolTTFTMiss(d.model, d.deadline)
			s.cancelDispatch(provider, pr)
			d.lastErr = "timeout waiting for first response"
			d.lastErrCode = http.StatusGatewayTimeout
			if s.metrics != nil {
				s.metrics.IncCounter("inference_dispatches_total", MetricLabel{"result", "timeout"})
			}
			s.ddIncr("inference.dispatches", []string{"status:timeout"})
			d.provider = nil
			d.pr = nil
			return outcomeRetry
		case <-r.Context().Done():
			remainingPrimary.Stop()
			s.cancelDispatch(provider, pr)
			d.refundReservation()
			return outcomeClientGone
		}
	}
}

// racePrimaryFailedWaitBackup handles the race sub-case where the primary errored
// (already recorded): wait the remaining deadline for the backup, promoting it to
// the committed/accepted provider on success. This is the former
// `primaryFailedBackupWait` loop.
func (d *dispatchState) racePrimaryFailedWaitBackup(backupProvider *registry.Provider, backupPR *registry.PendingRequest, backupHeld []string) dispatchOutcome {
	s := d.s
	r := d.r
	backupDeadline := time.NewTimer(d.deadline - d.speculativeAt)
	for {
		select {
		case chunk, ok := <-backupPR.ChunkCh:
			if ok && len(backupHeld) < maxHeldBoilerplate && isBoilerplateChunk(chunk) {
				backupHeld = append(backupHeld, chunk)
				backupPR.MarkFirstChunkArrived()
				continue
			}
			backupDeadline.Stop()
			if ok {
				d.provider = backupProvider
				d.pr = backupPR
				d.requestID = d.pr.RequestID
				d.heldChunks = backupHeld
				d.firstChunk = chunk
				d.pr.MarkFirstChunkArrived()
				d.committed = true
			} else {
				select {
				case errMsg2 := <-backupPR.ErrorCh:
					d.excludeProviders[backupProvider.ID] = struct{}{}
					s.cancelDispatch(backupProvider, backupPR)
					d.lastErr = errMsg2.Error
					d.lastErrCode = errMsg2.StatusCode
					d.lastFailedVersion = failedProviderVersion(backupProvider)
					d.noteDispatchRetry(backupProvider, backupPR, errMsg2.StatusCode, &backupHeld)
					d.provider = nil
					d.pr = nil
					return outcomeRetry
				default:
					d.provider = backupProvider
					d.pr = backupPR
					d.requestID = d.pr.RequestID
					d.heldChunks = backupHeld
					d.committed = true
				}
			}
			return outcomeCommitted
		case <-backupPR.AcceptedCh:
			backupDeadline.Stop()
			d.provider = backupProvider
			d.pr = backupPR
			d.requestID = d.pr.RequestID
			d.heldChunks = backupHeld
			d.accepted = true
			return outcomeAccepted
		case errMsg2 := <-backupPR.ErrorCh:
			backupDeadline.Stop()
			d.excludeProviders[backupProvider.ID] = struct{}{}
			s.cancelDispatch(backupProvider, backupPR)
			d.lastErr = errMsg2.Error
			d.lastErrCode = errMsg2.StatusCode
			d.lastFailedVersion = failedProviderVersion(backupProvider)
			s.noteDispatchProviderError(backupProvider, backupPR, errMsg2.StatusCode, &backupHeld)
			d.provider = nil
			d.pr = nil
			return outcomeRetry
		case <-backupDeadline.C:
			if len(backupHeld) > 0 {
				// Backup preamble liveness — promote it and extend
				// by the preamble-to-content budget for first content.
				d.provider = backupProvider
				d.pr = backupPR
				d.requestID = d.pr.RequestID
				d.heldChunks = backupHeld
				d.accepted = true
				d.preambleLiveness = true
				return outcomeAccepted
			}
			d.excludeProviders[backupProvider.ID] = struct{}{}
			s.registry.RecordWarmPoolTTFTMiss(d.model, d.deadline)
			s.cancelDispatch(backupProvider, backupPR)
			d.lastErr = "timeout waiting for first response (backup)"
			d.lastErrCode = http.StatusGatewayTimeout
			if s.metrics != nil {
				s.metrics.IncCounter("inference_dispatches_total", MetricLabel{"result", "timeout"})
			}
			s.ddIncr("inference.dispatches", []string{"status:timeout"})
			d.provider = nil
			d.pr = nil
			return outcomeRetry
		case <-r.Context().Done():
			backupDeadline.Stop()
			s.cancelDispatch(backupProvider, backupPR)
			d.refundReservation()
			return outcomeClientGone
		}
	}
}

// raceBackupErrWaitPrimary handles the race sub-case where the backup errored
// (already recorded): wait the remaining deadline for the primary. This is the
// former `backupFailedWaitPrimary` loop. d.provider/d.pr remain the primary.
func (d *dispatchState) raceBackupErrWaitPrimary(provider *registry.Provider, pr *registry.PendingRequest) dispatchOutcome {
	s := d.s
	r := d.r
	primaryDeadline := time.NewTimer(d.deadline - d.speculativeAt)
	for {
		select {
		case chunk, ok := <-pr.ChunkCh:
			if ok && len(d.heldChunks) < maxHeldBoilerplate && isBoilerplateChunk(chunk) {
				d.heldChunks = append(d.heldChunks, chunk)
				pr.MarkFirstChunkArrived()
				continue
			}
			primaryDeadline.Stop()
			if ok {
				d.firstChunk = chunk
				pr.MarkFirstChunkArrived()
				d.committed = true
			} else {
				select {
				case errMsg2 := <-pr.ErrorCh:
					d.excludeProviders[provider.ID] = struct{}{}
					s.cancelDispatch(provider, pr)
					d.lastErr = errMsg2.Error
					d.lastErrCode = errMsg2.StatusCode
					d.lastFailedVersion = failedProviderVersion(provider)
					d.noteDispatchRetry(provider, pr, errMsg2.StatusCode, &d.heldChunks)
					d.provider = nil
					d.pr = nil
					return outcomeRetry
				default:
					d.committed = true
				}
			}
			return outcomeCommitted
		case <-pr.AcceptedCh:
			primaryDeadline.Stop()
			d.accepted = true
			return outcomeAccepted
		case errMsg2 := <-pr.ErrorCh:
			primaryDeadline.Stop()
			d.excludeProviders[provider.ID] = struct{}{}
			s.cancelDispatch(provider, pr)
			d.lastErr = errMsg2.Error
			d.lastErrCode = errMsg2.StatusCode
			d.lastFailedVersion = failedProviderVersion(provider)
			s.noteDispatchProviderError(provider, pr, errMsg2.StatusCode, &d.heldChunks)
			d.provider = nil
			d.pr = nil
			return outcomeRetry
		case <-primaryDeadline.C:
			if len(d.heldChunks) > 0 {
				// Primary preamble liveness — extend by the
				// preamble-to-content budget instead of failing.
				d.accepted = true
				d.preambleLiveness = true
				return outcomeAccepted
			}
			d.excludeProviders[provider.ID] = struct{}{}
			s.registry.RecordWarmPoolTTFTMiss(d.model, d.deadline)
			s.cancelDispatch(provider, pr)
			d.lastErr = "timeout waiting for first response"
			d.lastErrCode = http.StatusGatewayTimeout
			if s.metrics != nil {
				s.metrics.IncCounter("inference_dispatches_total", MetricLabel{"result", "timeout"})
			}
			s.ddIncr("inference.dispatches", []string{"status:timeout"})
			d.provider = nil
			d.pr = nil
			return outcomeRetry
		case <-r.Context().Done():
			primaryDeadline.Stop()
			s.cancelDispatch(provider, pr)
			d.refundReservation()
			return outcomeClientGone
		}
	}
}
