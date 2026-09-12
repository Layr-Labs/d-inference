package api

import (
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// The race has already ruled out preamble and any earlier empty completion.
// A closed chunk stream can carry a queued error, so identify that terminal
// before cancelling the other racer or recording a speculative winner.
func (d *dispatchState) resolvePrimaryRaceChunk(chunk registry.ProviderChunk, ok bool, backupProvider *registry.Provider, backupPR *registry.PendingRequest, backupHeld []string) dispatchOutcome {
	if !ok {
		select {
		case errMsg := <-d.pr.ErrorCh:
			return d.resolvePrimaryRaceError(errMsg, backupProvider, backupPR, backupHeld)
		default:
		}
	}
	d.s.cancelDispatch(backupProvider, backupPR, cancelCauseHedgeLoser)
	d.markSpeculativeLoser(backupPR)
	if ok {
		d.commitFirstContent(d.pr, chunk.Data)
	}
	d.committed = true
	return outcomeCommitted
}

func (d *dispatchState) resolveBackupRaceChunk(chunk registry.ProviderChunk, ok bool, backupProvider *registry.Provider, backupPR *registry.PendingRequest, backupHeld []string) dispatchOutcome {
	if !ok {
		select {
		case errMsg := <-backupPR.ErrorCh:
			return d.resolveBackupRaceError(errMsg, backupProvider, backupPR, backupHeld)
		default:
		}
	}
	d.s.cancelDispatch(d.provider, d.pr, cancelCauseHedgeLoser)
	d.s.ddIncr("inference.speculative_win", []string{"model:" + d.model})
	d.s.registry.RecordWarmPoolSpeculativeWon(d.model)
	d.markSpeculativeLoser(d.pr)
	backupPR.BackupWon.Store(true)
	d.provider = backupProvider
	d.pr = backupPR
	d.requestID = backupPR.RequestID
	d.heldChunks = backupHeld
	// The serving backend and any later failure now belong to the backup.
	d.noteServingSlot()
	if ok {
		d.commitFirstContent(backupPR, chunk.Data)
	}
	d.committed = true
	return outcomeCommitted
}

// Closed-chunk and direct error events share the same failure transition.
// Buffered content still wins before its terminal error; otherwise only the
// failed attempt is retired and the survivor retains its remaining deadline.
func (d *dispatchState) resolvePrimaryRaceError(errMsg protocol.InferenceErrorMessage, backupProvider *registry.Provider, backupPR *registry.PendingRequest, backupHeld []string) dispatchOutcome {
	s := d.s
	provider, pr := d.provider, d.pr
	// Primary failed. Keep waiting for backup.
	if chunk, ok := drainReadyFirstContent(pr, &d.heldChunks); ok {
		if emptyCompletionPrecedesChunk(backupPR, chunk) {
			return d.awaitBackupEmptyCompletion(
				provider, pr, backupProvider, backupPR, backupHeld)
		}
		s.cancelDispatch(backupProvider, backupPR, cancelCauseHedgeLoser)
		d.markSpeculativeLoser(backupPR)
		d.commitFirstContent(pr, chunk.Data)
		d.committed = true
		d.initialError = &errMsg
		return outcomeCommitted
	}
	d.excludeProviders[provider.ID] = struct{}{}
	s.cancelDispatchAfterTerminal(provider, pr)
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
}

func (d *dispatchState) resolveBackupRaceError(errMsg protocol.InferenceErrorMessage, backupProvider *registry.Provider, backupPR *registry.PendingRequest, backupHeld []string) dispatchOutcome {
	s := d.s
	provider, pr := d.provider, d.pr
	// Backup failed. Keep waiting for primary.
	if chunk, ok := drainReadyFirstContent(backupPR, &backupHeld); ok {
		if emptyCompletionPrecedesChunk(pr, chunk) {
			return d.awaitPrimaryEmptyCompletion(backupProvider, backupPR)
		}
		s.cancelDispatch(provider, pr, cancelCauseHedgeLoser)
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
	s.cancelDispatchAfterTerminal(backupProvider, backupPR)
	d.lastFailedVersion = failedProviderVersion(backupProvider)
	d.updateSpeculativeFailure(backupPR, errMsg)
	d.noteProviderError(backupProvider, backupPR, errMsg.StatusCode, errMsg.Error, errMsg.ErrorReason, errMsg.TerminalCause, &backupHeld, errMsg.CoordinatorCause)
	// Preserve a deterministic-unservable verdict from this loser so the
	// surviving primary's error can't mask it (see latchDeterministicLoser).
	d.latchDeterministicLoser(backupProvider, errMsg)
	pr.ResolveSpeculativeEmptyCompletion(true)
	return d.raceBackupErrWaitPrimary(provider, pr)
}
