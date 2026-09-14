package dispatch

import (
	"net/http"
	"time"

	attemptpolicy "github.com/eigeninference/d-inference/coordinator/inference/attempt"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/telemetry/metrics"
)

func emptyCompletionPrecedesChunk(
	empty *registry.PendingRequest,
	chunk registry.ProviderChunk,
) bool {
	completedAt, ok := empty.OnTimeEmptyCompletionIngress()
	return ok &&
		!chunk.ReceivedAt.IsZero() &&
		!completedAt.After(chunk.ReceivedAt)
}

func (d *execution) awaitPrimaryEmptyCompletion(
	backupProvider *registry.Provider,
	backupPR *registry.PendingRequest,
) dispatchOutcome {
	d.pr.ResolveSpeculativeEmptyCompletion(true)
	d.s.deps.Attempts().Cancel(backupProvider, backupPR, attemptpolicy.CancelCauseHedgeLoser)
	d.markSpeculativeLoser(backupPR)
	return d.waitAccepted()
}

func (d *execution) awaitBackupEmptyCompletion(
	primaryProvider *registry.Provider,
	primaryPR *registry.PendingRequest,
	backupProvider *registry.Provider,
	backupPR *registry.PendingRequest,
	backupHeld []string,
) dispatchOutcome {
	backupPR.ResolveSpeculativeEmptyCompletion(true)
	d.s.deps.Attempts().Cancel(primaryProvider, primaryPR, attemptpolicy.CancelCauseHedgeLoser)
	d.s.deps.Counters.Incr("inference.speculative_win", []string{"model:" + d.model})
	d.s.deps.Registry().RecordWarmPoolSpeculativeWon(d.model)
	d.markSpeculativeLoser(primaryPR)
	backupPR.BackupWon.Store(true)
	if ap := backupPR.Profile; ap != nil {
		ap.BackupWon.Store(true)
		if primaryPR != nil {
			ap.CopyPreDispatchFrom(primaryPR.Profile)
		}
	}
	d.provider = backupProvider
	d.pr = backupPR
	d.requestID = backupPR.RequestID
	d.heldChunks = backupHeld
	d.noteServingSlot()
	return d.waitAccepted()
}

// runRace is the speculative `race` loop: primary (d.provider/d.pr) vs backup,
// first CONTENT chunk wins; the loser is cancelled. Preamble from each racer is
// buffered separately (held chunks must never mix providers). On a racer error the
// surviving racer is waited on via a sub-loop. Returns the waitFirstChunk outcome
// set; on a backup win d.provider/d.pr/d.requestID/d.heldChunks are swapped to the backup.
func (d *execution) runRace(backupProvider *registry.Provider, backupPR *registry.PendingRequest) dispatchOutcome {
	s := d.s
	r := d.r
	provider, pr := d.provider, d.pr

	raceDeadline := time.NewTimer(d.firstTokenWait(d.deadline - d.speculativeAt))
	// One-shot extension: when the race deadline expires but a racer
	// has shown liveness (preamble received), the race continues up to
	// leftover first-token budget (capped by preambleContentTimeout).
	raceExtended := false
	// Preamble chunks from the backup are buffered separately —
	// held chunks must never mix providers.
	var backupHeld []string
	primaryCompletion := pr.CompletionIngressSignal()
	backupCompletion := backupPR.CompletionIngressSignal()

	for {
		select {
		case chunk, ok := <-pr.ChunkCh:
			if ok && holdPreContentBoilerplate(pr, chunk, &d.heldChunks) {
				// Preamble only — the primary hasn't proven it can
				// generate; keep the backup racing for first content.
				if completedAt, empty := backupPR.OnTimeEmptyCompletionIngress(); empty &&
					!pr.ContentIngressAtOrBefore(completedAt) {
					raceDeadline.Stop()
					return d.awaitBackupEmptyCompletion(
						provider, pr, backupProvider, backupPR, backupHeld)
				}
				continue
			}
			if ok && emptyCompletionPrecedesChunk(backupPR, chunk) {
				raceDeadline.Stop()
				return d.awaitBackupEmptyCompletion(
					provider, pr, backupProvider, backupPR, backupHeld)
			}
			if !ok {
				primaryAt, primaryEmpty := pr.OnTimeEmptyCompletionIngress()
				backupAt, backupEmpty := backupPR.OnTimeEmptyCompletionIngress()
				if backupEmpty && (!primaryEmpty || backupAt.Before(primaryAt)) {
					raceDeadline.Stop()
					return d.awaitBackupEmptyCompletion(
						provider, pr, backupProvider, backupPR, backupHeld)
				}
			}
			// Primary wins!
			raceDeadline.Stop()
			s.deps.Attempts().Cancel(backupProvider, backupPR, attemptpolicy.CancelCauseHedgeLoser)
			if ok {
				d.markSpeculativeLoser(backupPR)
				d.commitFirstContent(pr, chunk.Data)
				d.committed = true
			} else {
				select {
				case errMsg := <-pr.ErrorCh:
					// Primary failed but we already cancelled backup.
					d.markSpeculativeLoser(backupPR)
					d.excludeProviders[provider.ID] = struct{}{}
					s.deps.Attempts().CancelAfterTerminal(provider, pr)
					d.setLastInferenceError(provider, errMsg)
					d.lastFailedVersion = failedProviderVersion(provider)
					d.noteDispatchRetry(provider, pr, errMsg.StatusCode, errMsg.Error, errMsg.ErrorReason, errMsg.TerminalCause, &d.heldChunks, errMsg.CoordinatorCause)
					d.provider = nil
					d.pr = nil
					return outcomeRetry
				default:
					d.markSpeculativeLoser(backupPR)
					d.committed = true
				}
			}
			return outcomeCommitted

		case chunk, ok := <-backupPR.ChunkCh:
			if ok && holdPreContentBoilerplate(backupPR, chunk, &backupHeld) {
				// Backup preamble doesn't win the race — first CONTENT does.
				if completedAt, empty := pr.OnTimeEmptyCompletionIngress(); empty &&
					!backupPR.ContentIngressAtOrBefore(completedAt) {
					raceDeadline.Stop()
					return d.awaitPrimaryEmptyCompletion(backupProvider, backupPR)
				}
				continue
			}
			if ok && emptyCompletionPrecedesChunk(pr, chunk) {
				raceDeadline.Stop()
				return d.awaitPrimaryEmptyCompletion(backupProvider, backupPR)
			}
			if !ok {
				primaryAt, primaryEmpty := pr.OnTimeEmptyCompletionIngress()
				backupAt, backupEmpty := backupPR.OnTimeEmptyCompletionIngress()
				if primaryEmpty && (!backupEmpty || primaryAt.Before(backupAt)) {
					raceDeadline.Stop()
					return d.awaitPrimaryEmptyCompletion(backupProvider, backupPR)
				}
			}
			// Backup wins!
			raceDeadline.Stop()
			s.deps.Attempts().Cancel(provider, pr, attemptpolicy.CancelCauseHedgeLoser)
			s.deps.Counters.Incr("inference.speculative_win", []string{"model:" + d.model})
			s.deps.Registry().RecordWarmPoolSpeculativeWon(d.model)
			if ok {
				d.markSpeculativeLoser(pr)
				backupPR.BackupWon.Store(true)
				d.provider = backupProvider
				d.pr = backupPR
				d.requestID = d.pr.RequestID
				d.heldChunks = backupHeld
				// The backup is now the serving slot; re-latch so a
				// post-commit failure books under ITS backend, not the
				// cancelled primary's.
				d.noteServingSlot()
				d.commitFirstContent(d.pr, chunk.Data)
				d.committed = true
			} else {
				select {
				case errMsg := <-backupPR.ErrorCh:
					// Backup failed too. Keep primary context for retry.
					d.excludeProviders[backupProvider.ID] = struct{}{}
					d.lastFailedVersion = failedProviderVersion(backupProvider)
					d.updateSpeculativeFailure(backupPR, errMsg)
					d.noteProviderError(backupProvider, backupPR, errMsg.StatusCode, errMsg.Error, errMsg.ErrorReason, errMsg.TerminalCause, &backupHeld, errMsg.CoordinatorCause)
					// Preserve a deterministic-unservable verdict from this loser so the
					// surviving primary's error can't mask it (see latchDeterministicLoser).
					d.latchDeterministicLoser(backupProvider, errMsg)
					// Wait remaining deadline for primary.
					return d.raceBackupChunkClosedWaitPrimary(provider, pr)
				default:
					// Backup channel closed with no error — treat as committed.
					s.deps.Attempts().Cancel(provider, pr, attemptpolicy.CancelCauseHedgeLoser)
					d.markSpeculativeLoser(pr)
					backupPR.BackupWon.Store(true)
					d.provider = backupProvider
					d.pr = backupPR
					d.requestID = d.pr.RequestID
					d.heldChunks = backupHeld
					d.noteServingSlot()
					d.committed = true
				}
			}
			return outcomeCommitted

		case <-primaryCompletion:
			primaryCompletion = nil
			completedAt, empty := pr.OnTimeEmptyCompletionIngress()
			if !empty || backupPR.ContentIngressAtOrBefore(completedAt) {
				continue
			}
			if backupAt, backupEmpty := backupPR.OnTimeEmptyCompletionIngress(); backupEmpty && backupAt.Before(completedAt) {
				raceDeadline.Stop()
				return d.awaitBackupEmptyCompletion(
					provider, pr, backupProvider, backupPR, backupHeld)
			}
			raceDeadline.Stop()
			return d.awaitPrimaryEmptyCompletion(backupProvider, backupPR)

		case <-backupCompletion:
			backupCompletion = nil
			completedAt, empty := backupPR.OnTimeEmptyCompletionIngress()
			if !empty || pr.ContentIngressAtOrBefore(completedAt) {
				continue
			}
			if primaryAt, primaryEmpty := pr.OnTimeEmptyCompletionIngress(); primaryEmpty && primaryAt.Before(completedAt) {
				raceDeadline.Stop()
				return d.awaitPrimaryEmptyCompletion(backupProvider, backupPR)
			}
			raceDeadline.Stop()
			return d.awaitBackupEmptyCompletion(
				provider, pr, backupProvider, backupPR, backupHeld)

		case <-pr.AcceptedCh:
			// Acceptance never wins a race. Both providers keep racing until
			// real content, error, or the absolute deadline.
			continue

		case <-backupPR.AcceptedCh:
			continue

		case errMsg := <-pr.ErrorCh:
			// Primary failed. Keep waiting for backup.
			raceDeadline.Stop()
			if chunk, ok := drainReadyFirstContent(pr, &d.heldChunks); ok {
				if emptyCompletionPrecedesChunk(backupPR, chunk) {
					return d.awaitBackupEmptyCompletion(
						provider, pr, backupProvider, backupPR, backupHeld)
				}
				s.deps.Attempts().Cancel(backupProvider, backupPR, attemptpolicy.CancelCauseHedgeLoser)
				d.markSpeculativeLoser(backupPR)
				d.commitFirstContent(pr, chunk.Data)
				d.committed = true
				d.initialError = &errMsg
				return outcomeCommitted
			}
			d.excludeProviders[provider.ID] = struct{}{}
			s.deps.Attempts().CancelAfterTerminal(provider, pr)
			d.lastFailedVersion = failedProviderVersion(provider)
			d.updateSpeculativeFailure(pr, errMsg)
			d.noteProviderError(provider, pr, errMsg.StatusCode, errMsg.Error, errMsg.ErrorReason, errMsg.TerminalCause, &d.heldChunks, errMsg.CoordinatorCause)
			// Preserve a deterministic-unservable verdict from this loser so the
			// surviving backup's error can't mask it (see latchDeterministicLoser).
			d.latchDeterministicLoser(provider, errMsg)
			d.requestID = ""
			d.provider = nil
			d.pr = nil
			backupPR.ResolveSpeculativeEmptyCompletion(true)
			return d.racePrimaryFailedWaitBackup(backupProvider, backupPR, backupHeld)

		case errMsg := <-backupPR.ErrorCh:
			// Backup failed. Keep waiting for primary.
			raceDeadline.Stop()
			if chunk, ok := drainReadyFirstContent(backupPR, &backupHeld); ok {
				if emptyCompletionPrecedesChunk(pr, chunk) {
					return d.awaitPrimaryEmptyCompletion(backupProvider, backupPR)
				}
				s.deps.Attempts().Cancel(provider, pr, attemptpolicy.CancelCauseHedgeLoser)
				d.markSpeculativeLoser(pr)
				backupPR.BackupWon.Store(true)
				d.provider = backupProvider
				d.pr = backupPR
				d.requestID = backupPR.RequestID
				d.heldChunks = backupHeld
				d.noteServingSlot()
				d.commitFirstContent(backupPR, chunk.Data)
				d.committed = true
				d.initialError = &errMsg
				return outcomeCommitted
			}
			d.excludeProviders[backupProvider.ID] = struct{}{}
			s.deps.Attempts().CancelAfterTerminal(backupProvider, backupPR)
			d.lastFailedVersion = failedProviderVersion(backupProvider)
			d.updateSpeculativeFailure(backupPR, errMsg)
			d.noteProviderError(backupProvider, backupPR, errMsg.StatusCode, errMsg.Error, errMsg.ErrorReason, errMsg.TerminalCause, &backupHeld, errMsg.CoordinatorCause)
			// Preserve a deterministic-unservable verdict from this loser so the
			// surviving primary's error can't mask it (see latchDeterministicLoser).
			d.latchDeterministicLoser(backupProvider, errMsg)
			pr.ResolveSpeculativeEmptyCompletion(true)
			return d.raceBackupErrWaitPrimary(provider, pr)

		case <-raceDeadline.C:
			// A token that is already buffered beats the timer: the backup is
			// dispatched synchronously in runSpeculative, so an on-time primary
			// token can be sitting in ChunkCh when a zero-leftover timer fires.
			if chunk, ok := drainReadyFirstContent(pr, &d.heldChunks); ok {
				if emptyCompletionPrecedesChunk(backupPR, chunk) {
					return d.awaitBackupEmptyCompletion(
						provider, pr, backupProvider, backupPR, backupHeld)
				}
				s.deps.Attempts().Cancel(backupProvider, backupPR, attemptpolicy.CancelCauseHedgeLoser)
				d.markSpeculativeLoser(backupPR)
				d.commitFirstContent(pr, chunk.Data)
				d.committed = true
				return outcomeCommitted
			}
			if chunk, ok := drainReadyFirstContent(backupPR, &backupHeld); ok {
				if emptyCompletionPrecedesChunk(pr, chunk) {
					return d.awaitPrimaryEmptyCompletion(backupProvider, backupPR)
				}
				s.deps.Attempts().Cancel(provider, pr, attemptpolicy.CancelCauseHedgeLoser)
				s.deps.Counters.Incr("inference.speculative_win", []string{"model:" + d.model})
				s.deps.Registry().RecordWarmPoolSpeculativeWon(d.model)
				d.markSpeculativeLoser(pr)
				backupPR.BackupWon.Store(true)
				d.provider = backupProvider
				d.pr = backupPR
				d.requestID = d.pr.RequestID
				d.heldChunks = backupHeld
				d.noteServingSlot()
				d.commitFirstContent(d.pr, chunk.Data)
				d.committed = true
				return outcomeCommitted
			}
			if pr.FirstContentIngressArrivedByDeadline() ||
				backupPR.FirstContentIngressArrivedByDeadline() {
				continue
			}
			if !raceExtended && (len(d.heldChunks) > 0 || len(backupHeld) > 0) {
				// Liveness from at least one racer: don't fail at the
				// relative TTFT slice — extend once by leftover
				// request-absolute first-token budget, capped by
				// preambleContentTimeout (zero bytes have reached the
				// client; a genuine cold load would have signalled
				// AcceptedCh).
				ext := d.firstTokenWait(preambleContentTimeout)
				if ext > preambleContentTimeout {
					ext = preambleContentTimeout
				}
				if ext > 0 {
					raceExtended = true
					raceDeadline = time.NewTimer(ext)
					continue
				}
			}
			if !s.deps.Attempts().CancelForFirstContentTimeout(provider, pr) {
				continue
			}
			if !s.deps.Attempts().CancelForFirstContentTimeout(backupProvider, backupPR) {
				// The primary was cancelled for the timeout but the backup
				// won its ingress race: record the primary's timeout (route
				// outcome + attempt profile) before its identity is cleared.
				d.updateSpeculativeTimeout(pr, "first_chunk_timeout")
				d.excludeProviders[provider.ID] = struct{}{}
				d.setLastError("timeout waiting for first response", http.StatusGatewayTimeout)
				d.provider = nil
				d.pr = nil
				d.requestID = ""
				backupPR.ResolveSpeculativeEmptyCompletion(true)
				return d.racePrimaryFailedWaitBackup(
					backupProvider, backupPR, backupHeld)
			}
			// Both missed deadline. A racer that held preamble (role
			// then stall) is a 504-shaped sickness — feed the breaker
			// before cancelling, mirroring the single-provider
			// acceptedWait timeout path so a stalling provider/model
			// (shape-keyed) trips its cooldown.
			// Attribute each provider's complete initial+racing interval. The
			// prior extension-only check missed stalls split across phases.
			if providerAttemptAttributableStall(pr, d.deadline) {
				s.deps.Attempts().Error(provider.ID, pr, http.StatusGatewayTimeout, "", "", "")
			}
			if providerAttemptAttributableStall(
				backupPR, d.deadline-d.speculativeAt) {
				s.deps.Attempts().Error(backupProvider.ID, backupPR, http.StatusGatewayTimeout, "", "", "")
			}
			s.deps.Registry().RecordWarmPoolTTFTMiss(d.model, d.deadline)
			d.updateSpeculativeTimeout(backupPR, "first_chunk_timeout")
			d.excludeProviders[provider.ID] = struct{}{}
			d.excludeProviders[backupProvider.ID] = struct{}{}
			d.setLastError("timeout waiting for first response (both providers)", http.StatusGatewayTimeout)
			if s.deps.Metrics() != nil {
				s.deps.Metrics().IncCounter("inference_dispatches_total", metrics.Label{Name: "result", Value: "timeout"})
			}
			s.deps.Counters.Incr("inference.dispatches", []string{"status:timeout"})
			d.provider = nil
			d.pr = nil
			return outcomeRetry

		case <-r.Context().Done():
			raceDeadline.Stop()
			d.updateSpeculativeClientGone(backupPR)
			s.deps.Attempts().Cancel(provider, pr, attemptpolicy.CancelCauseClientGonePre)
			s.deps.Attempts().Cancel(backupProvider, backupPR, attemptpolicy.CancelCauseClientGonePre)
			d.refundReservation()
			return outcomeClientGone
		}
	}
}
