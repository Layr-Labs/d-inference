package dispatch

import (
	"net/http"
	"time"

	attemptpolicy "github.com/eigeninference/d-inference/coordinator/inference/attempt"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/telemetry/metrics"
)

// raceBackupChunkClosedWaitPrimary handles the race sub-case where the backup's
// ChunkCh closed with an error (already recorded by the caller): wait the
// remaining deadline for the primary. This is the former `backupFailedPrimaryWait`
// loop. d.provider/d.pr remain the primary throughout (the backup already lost).
func (d *execution) raceBackupChunkClosedWaitPrimary(provider *registry.Provider, pr *registry.PendingRequest) dispatchOutcome {
	s := d.s
	r := d.r
	remainingPrimary := time.NewTimer(d.firstTokenWait(d.deadline - d.speculativeAt))
	for {
		select {
		case chunk, ok := <-pr.ChunkCh:
			if ok && holdPreContentBoilerplate(pr, chunk, &d.heldChunks) {
				continue
			}
			remainingPrimary.Stop()
			if ok {
				d.commitFirstContent(pr, chunk.Data)
				d.committed = true
			} else {
				select {
				case errMsg2 := <-pr.ErrorCh:
					d.excludeProviders[provider.ID] = struct{}{}
					s.deps.Attempts().CancelAfterTerminal(provider, pr)
					d.setLastInferenceError(provider, errMsg2)
					d.lastFailedVersion = failedProviderVersion(provider)
					d.updateSpeculativeFailure(pr, errMsg2)
					d.noteDispatchRetry(provider, pr, errMsg2.StatusCode, errMsg2.Error, errMsg2.ErrorReason, errMsg2.TerminalCause, &d.heldChunks, errMsg2.CoordinatorCause)
					d.provider = nil
					d.pr = nil
					d.requestID = ""
					return outcomeRetry
				default:
					d.committed = true
				}
			}
			return outcomeCommitted
		case <-pr.AcceptedCh:
			continue
		case errMsg2 := <-pr.ErrorCh:
			// Defensive: both ErrorCh senders currently send before
			// closing ChunkCh (the closed-ChunkCh check above catches
			// them), but a direct arm keeps this loop correct if that
			// ordering ever changes — mirroring its sibling wait loops.
			remainingPrimary.Stop()
			if d.commitReadyFirstContent(pr, &d.heldChunks, errMsg2) {
				return outcomeCommitted
			}
			d.excludeProviders[provider.ID] = struct{}{}
			s.deps.Attempts().CancelAfterTerminal(provider, pr)
			d.setLastInferenceError(provider, errMsg2)
			d.lastFailedVersion = failedProviderVersion(provider)
			d.updateSpeculativeFailure(pr, errMsg2)
			d.noteDispatchRetry(provider, pr, errMsg2.StatusCode, errMsg2.Error, errMsg2.ErrorReason, errMsg2.TerminalCause, &d.heldChunks, errMsg2.CoordinatorCause)
			d.provider = nil
			d.pr = nil
			d.requestID = ""
			return outcomeRetry
		case <-remainingPrimary.C:
			if chunk, ok := drainReadyFirstContent(pr, &d.heldChunks); ok {
				d.commitFirstContent(pr, chunk.Data)
				d.committed = true
				return outcomeCommitted
			}
			if pr.FirstContentIngressArrivedByDeadline() {
				continue
			}
			if len(d.heldChunks) > 0 && d.canExtendPreambleLiveness() {
				// Primary preamble liveness — continue in waitAccepted
				// on leftover request-absolute first-token budget.
				d.preambleLiveness = true
				return outcomeAccepted
			}
			if !s.deps.Attempts().CancelForFirstContentTimeout(provider, pr) {
				continue
			}
			// The PRIMARY timed out here (the backup's earlier error
			// is already recorded); report the timeout, not the
			// backup's stale error text.
			d.excludeProviders[provider.ID] = struct{}{}
			s.deps.Registry().RecordWarmPoolTTFTMiss(d.model, d.deadline)
			if providerAttemptAttributableStall(pr, d.deadline) {
				s.deps.Attempts().Error(provider.ID, pr, http.StatusGatewayTimeout, "", "", "")
			}
			d.updateSpeculativeTimeout(pr, "first_chunk_timeout")
			d.setLastError("timeout waiting for first response", http.StatusGatewayTimeout)
			if s.deps.Metrics() != nil {
				s.deps.Metrics().IncCounter("inference_dispatches_total", metrics.Label{Name: "result", Value: "timeout"})
			}
			s.deps.Counters.Incr("inference.dispatches", []string{"status:timeout"})
			d.provider = nil
			d.pr = nil
			d.requestID = ""
			return outcomeRetry
		case <-r.Context().Done():
			remainingPrimary.Stop()
			d.updateSpeculativeClientGone(pr)
			s.deps.Attempts().Cancel(provider, pr, attemptpolicy.CancelCauseClientGonePre)
			d.refundReservation()
			return outcomeClientGone
		}
	}
}

// racePrimaryFailedWaitBackup handles the race sub-case where the primary errored
// (already recorded): wait the remaining deadline for the backup, promoting it to
// the committed/accepted provider on success. This is the former
// `primaryFailedBackupWait` loop.
func (d *execution) racePrimaryFailedWaitBackup(backupProvider *registry.Provider, backupPR *registry.PendingRequest, backupHeld []string) dispatchOutcome {
	s := d.s
	r := d.r
	// The primary already failed and d.pr is cleared: the BACKUP is the only
	// racer left, so every failure or timeout below is the backup's. Re-latch
	// now so the terminal outcome names the backup's backend rather than
	// falling back to the dead primary's latch. When the primary's failure
	// latched a DETERMINISTIC verdict (latchDeterministicLoser just ran), the
	// re-latch is a no-op by design: the terminal response will be the
	// primary's 4xx/422/429, so the primary keeps the attribution even
	// though the backup keeps racing (noteServingSlotFor's freeze rule).
	d.noteServingSlotFor(backupPR)
	backupDeadline := time.NewTimer(d.firstTokenWait(d.deadline - d.speculativeAt))
	for {
		select {
		case chunk, ok := <-backupPR.ChunkCh:
			if ok && holdPreContentBoilerplate(backupPR, chunk, &backupHeld) {
				continue
			}
			backupDeadline.Stop()
			if ok {
				backupPR.BackupWon.Store(true)
				d.provider = backupProvider
				d.pr = backupPR
				d.requestID = d.pr.RequestID
				d.heldChunks = backupHeld
				d.commitFirstContent(d.pr, chunk.Data)
				d.committed = true
			} else {
				select {
				case errMsg2 := <-backupPR.ErrorCh:
					d.excludeProviders[backupProvider.ID] = struct{}{}
					s.deps.Attempts().CancelAfterTerminal(backupProvider, backupPR)
					d.setLastInferenceError(backupProvider, errMsg2)
					d.lastFailedVersion = failedProviderVersion(backupProvider)
					d.updateSpeculativeFailure(backupPR, errMsg2)
					d.noteDispatchRetry(backupProvider, backupPR, errMsg2.StatusCode, errMsg2.Error, errMsg2.ErrorReason, errMsg2.TerminalCause, &backupHeld, errMsg2.CoordinatorCause)
					d.provider = nil
					d.pr = nil
					return outcomeRetry
				default:
					backupPR.BackupWon.Store(true)
					d.provider = backupProvider
					d.pr = backupPR
					d.requestID = d.pr.RequestID
					d.heldChunks = backupHeld
					d.committed = true
				}
			}
			return outcomeCommitted
		case <-backupPR.AcceptedCh:
			continue
		case errMsg2 := <-backupPR.ErrorCh:
			backupDeadline.Stop()
			if chunk, ok := drainReadyFirstContent(backupPR, &backupHeld); ok {
				backupPR.BackupWon.Store(true)
				d.provider = backupProvider
				d.pr = backupPR
				d.requestID = backupPR.RequestID
				d.heldChunks = backupHeld
				d.noteServingSlot()
				d.commitFirstContent(backupPR, chunk.Data)
				d.committed = true
				d.initialError = &errMsg2
				return outcomeCommitted
			}
			d.excludeProviders[backupProvider.ID] = struct{}{}
			s.deps.Attempts().CancelAfterTerminal(backupProvider, backupPR)
			d.setLastInferenceError(backupProvider, errMsg2)
			d.lastFailedVersion = failedProviderVersion(backupProvider)
			d.updateSpeculativeFailure(backupPR, errMsg2)
			d.noteProviderError(backupProvider, backupPR, errMsg2.StatusCode, errMsg2.Error, errMsg2.ErrorReason, errMsg2.TerminalCause, &backupHeld, errMsg2.CoordinatorCause)
			d.provider = nil
			d.pr = nil
			return outcomeRetry
		case <-backupDeadline.C:
			if chunk, ok := drainReadyFirstContent(backupPR, &backupHeld); ok {
				backupPR.BackupWon.Store(true)
				d.provider = backupProvider
				d.pr = backupPR
				d.requestID = d.pr.RequestID
				d.heldChunks = backupHeld
				d.commitFirstContent(d.pr, chunk.Data)
				d.committed = true
				return outcomeCommitted
			}
			if backupPR.FirstContentIngressArrivedByDeadline() {
				continue
			}
			if len(backupHeld) > 0 && d.canExtendPreambleLiveness() {
				// Backup preamble liveness — promote it and continue
				// in waitAccepted on leftover first-token budget.
				backupPR.BackupWon.Store(true)
				d.provider = backupProvider
				d.pr = backupPR
				d.requestID = d.pr.RequestID
				d.heldChunks = backupHeld
				d.preambleLiveness = true
				return outcomeAccepted
			}
			if !s.deps.Attempts().CancelForFirstContentTimeout(backupProvider, backupPR) {
				continue
			}
			d.excludeProviders[backupProvider.ID] = struct{}{}
			s.deps.Registry().RecordWarmPoolTTFTMiss(d.model, d.deadline)
			if providerAttemptAttributableStall(
				backupPR, d.deadline-d.speculativeAt) {
				s.deps.Attempts().Error(backupProvider.ID, backupPR, http.StatusGatewayTimeout, "", "", "")
			}
			d.updateSpeculativeTimeout(backupPR, "first_chunk_timeout")
			d.setLastError("timeout waiting for first response (backup)", http.StatusGatewayTimeout)
			if s.deps.Metrics() != nil {
				s.deps.Metrics().IncCounter("inference_dispatches_total", metrics.Label{Name: "result", Value: "timeout"})
			}
			s.deps.Counters.Incr("inference.dispatches", []string{"status:timeout"})
			d.provider = nil
			d.pr = nil
			return outcomeRetry
		case <-r.Context().Done():
			backupDeadline.Stop()
			d.updateSpeculativeClientGone(backupPR)
			s.deps.Attempts().Cancel(backupProvider, backupPR, attemptpolicy.CancelCauseClientGonePre)
			d.refundReservation()
			return outcomeClientGone
		}
	}
}

// raceBackupErrWaitPrimary handles the race sub-case where the backup errored
// (already recorded): wait the remaining deadline for the primary. This is the
// former `backupFailedWaitPrimary` loop. d.provider/d.pr remain the primary.
func (d *execution) raceBackupErrWaitPrimary(provider *registry.Provider, pr *registry.PendingRequest) dispatchOutcome {
	s := d.s
	r := d.r
	primaryDeadline := time.NewTimer(d.firstTokenWait(d.deadline - d.speculativeAt))
	for {
		select {
		case chunk, ok := <-pr.ChunkCh:
			if ok && holdPreContentBoilerplate(pr, chunk, &d.heldChunks) {
				continue
			}
			primaryDeadline.Stop()
			if ok {
				d.commitFirstContent(pr, chunk.Data)
				d.committed = true
			} else {
				select {
				case errMsg2 := <-pr.ErrorCh:
					d.excludeProviders[provider.ID] = struct{}{}
					s.deps.Attempts().CancelAfterTerminal(provider, pr)
					d.setLastInferenceError(provider, errMsg2)
					d.lastFailedVersion = failedProviderVersion(provider)
					d.noteDispatchRetry(provider, pr, errMsg2.StatusCode, errMsg2.Error, errMsg2.ErrorReason, errMsg2.TerminalCause, &d.heldChunks, errMsg2.CoordinatorCause)
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
		case errMsg2 := <-pr.ErrorCh:
			primaryDeadline.Stop()
			if d.commitReadyFirstContent(pr, &d.heldChunks, errMsg2) {
				return outcomeCommitted
			}
			d.excludeProviders[provider.ID] = struct{}{}
			s.deps.Attempts().CancelAfterTerminal(provider, pr)
			d.setLastInferenceError(provider, errMsg2)
			d.lastFailedVersion = failedProviderVersion(provider)
			d.updateSpeculativeFailure(pr, errMsg2)
			d.noteProviderError(provider, pr, errMsg2.StatusCode, errMsg2.Error, errMsg2.ErrorReason, errMsg2.TerminalCause, &d.heldChunks, errMsg2.CoordinatorCause)
			d.provider = nil
			d.pr = nil
			d.requestID = ""
			return outcomeRetry
		case <-primaryDeadline.C:
			if chunk, ok := drainReadyFirstContent(pr, &d.heldChunks); ok {
				d.commitFirstContent(pr, chunk.Data)
				d.committed = true
				return outcomeCommitted
			}
			if pr.FirstContentIngressArrivedByDeadline() {
				continue
			}
			if len(d.heldChunks) > 0 && d.canExtendPreambleLiveness() {
				// Primary preamble liveness — continue in waitAccepted
				// on leftover request-absolute first-token budget.
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
			d.updateSpeculativeTimeout(pr, "first_chunk_timeout")
			d.setLastError("timeout waiting for first response", http.StatusGatewayTimeout)
			if s.deps.Metrics() != nil {
				s.deps.Metrics().IncCounter("inference_dispatches_total", metrics.Label{Name: "result", Value: "timeout"})
			}
			s.deps.Counters.Incr("inference.dispatches", []string{"status:timeout"})
			d.provider = nil
			d.pr = nil
			d.requestID = ""
			return outcomeRetry
		case <-r.Context().Done():
			primaryDeadline.Stop()
			d.updateSpeculativeClientGone(pr)
			s.deps.Attempts().Cancel(provider, pr, attemptpolicy.CancelCauseClientGonePre)
			d.refundReservation()
			return outcomeClientGone
		}
	}
}
