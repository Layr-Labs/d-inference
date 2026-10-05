package attempt

import (
	"context"
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/internal/inference/cancellation"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/firstcontent"
)

// Run races the primary against the backup for first content, keeping each
// provider's preamble separate and waiting on the survivor when a racer fails.
func (r *Race) Run(ctx context.Context, primary, backup RaceAttempt) RaceResult {
	r.result = RaceResult{Attempt: primary}
	provider, pr := primary.Provider, primary.Pending
	backupProvider, backupPR := backup.Provider, backup.Pending

	raceDeadline := r.config.Clock.Timer(r.config.Clock.Wait(r.config.Deadline - r.config.SpeculativeAt))
	// One-shot extension: when the race deadline expires but a racer
	// has shown liveness (preamble received), the race continues up to
	// leftover first-token budget (capped by preambleContentTimeout).
	raceExtended := false
	// Preamble chunks from the backup are buffered separately:
	// held chunks must never mix providers.
	primaryCompletion := pr.CompletionIngressSignal()
	backupCompletion := backupPR.CompletionIngressSignal()

	for {
		select {
		case chunk, ok := <-pr.ChunkCh:
			if ok && firstcontent.HoldPreContentBoilerplate(pr, chunk, &r.result.Attempt.HeldChunks) {
				// Preamble only: the primary hasn't proven it can
				// generate; keep the backup racing for first content.
				if completedAt, empty := backupPR.OnTimeEmptyCompletionIngress(); empty &&
					!pr.ContentIngressAtOrBefore(completedAt) {
					raceDeadline.Stop()
					return r.AwaitBackupEmpty(r.result.Attempt, backup)
				}
				continue
			}
			if ok && firstcontent.EmptyCompletionPrecedesChunk(backupPR, chunk) {
				raceDeadline.Stop()
				return r.AwaitBackupEmpty(r.result.Attempt, backup)
			}
			if !ok {
				primaryAt, primaryEmpty := pr.OnTimeEmptyCompletionIngress()
				backupAt, backupEmpty := backupPR.OnTimeEmptyCompletionIngress()
				if backupEmpty && (!primaryEmpty || backupAt.Before(primaryAt)) {
					raceDeadline.Stop()
					return r.AwaitBackupEmpty(r.result.Attempt, backup)
				}
			}
			// Primary wins!
			raceDeadline.Stop()
			r.deps.Cancel(backupProvider, backupPR, cancellation.CauseHedgeLoser)
			if ok {
				r.deps.Routes.SpeculativeLoser(backupPR)
				r.commit(pr, chunk.Data)
				r.result.Outcome = Committed
			} else {
				select {
				case errMsg := <-pr.ErrorCh:
					// Primary failed but we already cancelled backup.
					r.deps.Routes.SpeculativeLoser(backupPR)
					r.exclude(provider)
					r.deps.CancelTerminal(provider, pr)
					r.setFailure(provider, errMsg)
					r.failedVersion(provider)
					r.noteError(provider, pr, errMsg, &r.result.Attempt.HeldChunks, true)
					r.clearAttempt(false)
					return r.finish(Retry)
				default:
					r.deps.Routes.SpeculativeLoser(backupPR)
					r.result.Outcome = Committed
				}
			}
			return r.finish(Committed)

		case chunk, ok := <-backupPR.ChunkCh:
			if ok && firstcontent.HoldPreContentBoilerplate(backupPR, chunk, &backup.HeldChunks) {
				// Backup preamble doesn't win the race: first CONTENT does.
				if completedAt, empty := pr.OnTimeEmptyCompletionIngress(); empty &&
					!backupPR.ContentIngressAtOrBefore(completedAt) {
					raceDeadline.Stop()
					return r.AwaitPrimaryEmpty(r.result.Attempt, backup)
				}
				continue
			}
			if ok && firstcontent.EmptyCompletionPrecedesChunk(pr, chunk) {
				raceDeadline.Stop()
				return r.AwaitPrimaryEmpty(r.result.Attempt, backup)
			}
			if !ok {
				primaryAt, primaryEmpty := pr.OnTimeEmptyCompletionIngress()
				backupAt, backupEmpty := backupPR.OnTimeEmptyCompletionIngress()
				if primaryEmpty && (!backupEmpty || primaryAt.Before(backupAt)) {
					raceDeadline.Stop()
					return r.AwaitPrimaryEmpty(r.result.Attempt, backup)
				}
			}
			// Backup wins!
			raceDeadline.Stop()
			r.deps.Cancel(provider, pr, cancellation.CauseHedgeLoser)
			r.backupWon()
			if ok {
				r.deps.Routes.SpeculativeLoser(pr)
				backupPR.BackupWon.Store(true)
				r.result.Attempt = backup
				r.result.Attempt.RequestID = backupPR.RequestID
				// The backup is now the serving slot; re-latch so a
				// post-commit failure books under ITS backend, not the
				// cancelled primary's.
				r.noteServing(r.result.Attempt.Provider, r.result.Attempt.Pending)
				r.commit(r.result.Attempt.Pending, chunk.Data)
				r.result.Outcome = Committed
			} else {
				select {
				case errMsg := <-backupPR.ErrorCh:
					// Backup failed too. Keep primary context for retry.
					r.exclude(backupProvider)
					r.failedVersion(backupProvider)
					r.recordFailure(backupPR, errMsg)
					r.noteError(backupProvider, backupPR, errMsg, &backup.HeldChunks, false)
					// Preserve a deterministic-unservable verdict from this loser so the
					// surviving primary's error can't mask it (see RecordLoser).
					r.RecordLoser(backupProvider, errMsg)
					// Wait remaining deadline for primary.
					return r.waitPrimary(ctx, provider, pr, true)
				default:
					// Backup channel closed with no error: treat as committed.
					r.deps.Cancel(provider, pr, cancellation.CauseHedgeLoser)
					r.deps.Routes.SpeculativeLoser(pr)
					backupPR.BackupWon.Store(true)
					r.result.Attempt = backup
					r.result.Attempt.RequestID = backupPR.RequestID
					r.noteServing(r.result.Attempt.Provider, r.result.Attempt.Pending)
					r.result.Outcome = Committed
				}
			}
			return r.finish(Committed)

		case <-primaryCompletion:
			primaryCompletion = nil
			completedAt, empty := pr.OnTimeEmptyCompletionIngress()
			if !empty || backupPR.ContentIngressAtOrBefore(completedAt) {
				continue
			}
			if backupAt, backupEmpty := backupPR.OnTimeEmptyCompletionIngress(); backupEmpty && backupAt.Before(completedAt) {
				raceDeadline.Stop()
				return r.AwaitBackupEmpty(r.result.Attempt, backup)
			}
			raceDeadline.Stop()
			return r.AwaitPrimaryEmpty(r.result.Attempt, backup)

		case <-backupCompletion:
			backupCompletion = nil
			completedAt, empty := backupPR.OnTimeEmptyCompletionIngress()
			if !empty || pr.ContentIngressAtOrBefore(completedAt) {
				continue
			}
			if primaryAt, primaryEmpty := pr.OnTimeEmptyCompletionIngress(); primaryEmpty && primaryAt.Before(completedAt) {
				raceDeadline.Stop()
				return r.AwaitPrimaryEmpty(r.result.Attempt, backup)
			}
			raceDeadline.Stop()
			return r.AwaitBackupEmpty(r.result.Attempt, backup)

		case <-pr.AcceptedCh:
			// Acceptance never wins a race. Both providers keep racing until
			// real content, error, or the absolute deadline.
			continue

		case <-backupPR.AcceptedCh:
			continue

		case errMsg := <-pr.ErrorCh:
			// Primary failed. Keep waiting for backup.
			raceDeadline.Stop()
			if chunk, ok := firstcontent.DrainReadyFirstContent(pr, &r.result.Attempt.HeldChunks); ok {
				if firstcontent.EmptyCompletionPrecedesChunk(backupPR, chunk) {
					return r.AwaitBackupEmpty(r.result.Attempt, backup)
				}
				r.deps.Cancel(backupProvider, backupPR, cancellation.CauseHedgeLoser)
				r.deps.Routes.SpeculativeLoser(backupPR)
				r.commit(pr, chunk.Data)
				r.result.Outcome = Committed
				r.result.Content.InitialError = &errMsg
				return r.finish(Committed)
			}
			r.exclude(provider)
			r.deps.CancelTerminal(provider, pr)
			r.failedVersion(provider)
			r.recordFailure(pr, errMsg)
			r.noteError(provider, pr, errMsg, &r.result.Attempt.HeldChunks, false)
			// Preserve a deterministic-unservable verdict from this loser so the
			// surviving backup's error can't mask it (see RecordLoser).
			r.RecordLoser(provider, errMsg)
			r.result.Attempt.RequestID = ""
			r.clearAttempt(false)
			backupPR.ResolveSpeculativeEmptyCompletion(true)
			return r.waitBackup(ctx, backup)

		case errMsg := <-backupPR.ErrorCh:
			// Backup failed. Keep waiting for primary.
			raceDeadline.Stop()
			if chunk, ok := firstcontent.DrainReadyFirstContent(backupPR, &backup.HeldChunks); ok {
				if firstcontent.EmptyCompletionPrecedesChunk(pr, chunk) {
					return r.AwaitPrimaryEmpty(r.result.Attempt, backup)
				}
				r.deps.Cancel(provider, pr, cancellation.CauseHedgeLoser)
				r.deps.Routes.SpeculativeLoser(pr)
				backupPR.BackupWon.Store(true)
				r.result.Attempt = backup
				r.result.Attempt.RequestID = backupPR.RequestID
				r.noteServing(r.result.Attempt.Provider, r.result.Attempt.Pending)
				r.commit(backupPR, chunk.Data)
				r.result.Outcome = Committed
				r.result.Content.InitialError = &errMsg
				return r.finish(Committed)
			}
			r.exclude(backupProvider)
			r.deps.CancelTerminal(backupProvider, backupPR)
			r.failedVersion(backupProvider)
			r.recordFailure(backupPR, errMsg)
			r.noteError(backupProvider, backupPR, errMsg, &backup.HeldChunks, false)
			// Preserve a deterministic-unservable verdict from this loser so the
			// surviving primary's error can't mask it (see RecordLoser).
			r.RecordLoser(backupProvider, errMsg)
			pr.ResolveSpeculativeEmptyCompletion(true)
			return r.waitPrimary(ctx, provider, pr, false)

		case <-raceDeadline.C:
			// A token that is already buffered beats the timer: the backup is
			// dispatched synchronously in runSpeculative, so an on-time primary
			// token can be sitting in ChunkCh when a zero-leftover timer fires.
			if chunk, ok := firstcontent.DrainReadyFirstContent(pr, &r.result.Attempt.HeldChunks); ok {
				if firstcontent.EmptyCompletionPrecedesChunk(backupPR, chunk) {
					return r.AwaitBackupEmpty(r.result.Attempt, backup)
				}
				r.deps.Cancel(backupProvider, backupPR, cancellation.CauseHedgeLoser)
				r.deps.Routes.SpeculativeLoser(backupPR)
				r.commit(pr, chunk.Data)
				r.result.Outcome = Committed
				return r.finish(Committed)
			}
			if chunk, ok := firstcontent.DrainReadyFirstContent(backupPR, &backup.HeldChunks); ok {
				if firstcontent.EmptyCompletionPrecedesChunk(pr, chunk) {
					return r.AwaitPrimaryEmpty(r.result.Attempt, backup)
				}
				r.deps.Cancel(provider, pr, cancellation.CauseHedgeLoser)
				r.backupWon()
				r.deps.Routes.SpeculativeLoser(pr)
				backupPR.BackupWon.Store(true)
				r.result.Attempt = backup
				r.result.Attempt.RequestID = backupPR.RequestID
				r.noteServing(r.result.Attempt.Provider, r.result.Attempt.Pending)
				r.commit(r.result.Attempt.Pending, chunk.Data)
				r.result.Outcome = Committed
				return r.finish(Committed)
			}
			if pr.FirstContentIngressArrivedByDeadline() ||
				backupPR.FirstContentIngressArrivedByDeadline() {
				continue
			}
			if !raceExtended && (len(r.result.Attempt.HeldChunks) > 0 || len(backup.HeldChunks) > 0) {
				// Liveness from at least one racer: don't fail at the
				// relative TTFT slice; extend once by leftover
				// request-absolute first-token budget, capped by
				// preambleContentTimeout (zero bytes have reached the
				// client; a genuine cold load would have signalled
				// AcceptedCh).
				ext := r.config.Clock.Wait(firstcontent.PreambleContentTimeout)
				if ext > firstcontent.PreambleContentTimeout {
					ext = firstcontent.PreambleContentTimeout
				}
				if ext > 0 {
					raceExtended = true
					raceDeadline = r.config.Clock.Timer(ext)
					continue
				}
			}
			if !r.deps.CancelTimeout(provider, pr) {
				continue
			}
			if !r.deps.CancelTimeout(backupProvider, backupPR) {
				// The primary was cancelled for the timeout but the backup
				// won its ingress race: record the primary's timeout (route
				// outcome + attempt profile) before its identity is cleared.
				r.recordTimeout(pr)
				r.exclude(provider)
				r.setTimeout("timeout waiting for first response")
				r.clearAttempt(true)
				backupPR.ResolveSpeculativeEmptyCompletion(true)
				return r.waitBackup(ctx, backup)
			}
			// Both missed deadline. A racer that held preamble (role
			// then stall) is a 504-shaped sickness: feed the breaker
			// before cancelling, mirroring the single-provider
			// acceptedWait timeout path so a stalling provider/model
			// (shape-keyed) trips its cooldown.
			// Attribute each provider's complete initial+racing interval. The
			// prior extension-only check missed stalls split across phases.
			if firstcontent.ProviderAttemptAttributableStall(pr, r.config.Deadline) {
				r.deps.Effects.RecordError(provider.ID, pr, http.StatusGatewayTimeout, "", "", "")
			}
			if firstcontent.ProviderAttemptAttributableStall(
				backupPR, r.config.Deadline-r.config.SpeculativeAt) {
				r.deps.Effects.RecordError(backupProvider.ID, backupPR, http.StatusGatewayTimeout, "", "", "")
			}
			r.deps.Registry.RecordWarmPoolTTFTMiss(r.config.Model, r.config.Deadline)
			r.recordTimeout(backupPR)
			r.exclude(provider)
			r.exclude(backupProvider)
			r.setTimeout("timeout waiting for first response (both providers)")
			r.noteTimeout()
			r.clearAttempt(false)
			return r.finish(Retry)

		case <-ctx.Done():
			raceDeadline.Stop()
			r.recordClientGone(backupPR)
			r.deps.Cancel(provider, pr, cancellation.CauseClientGonePre)
			r.deps.Cancel(backupProvider, backupPR, cancellation.CauseClientGonePre)
			r.deps.Refund()
			return r.finish(ClientGone)
		}
	}
}
