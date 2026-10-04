package attempt

import (
	"context"
	"net/http"

	"github.com/eigeninference/d-inference/coordinator/internal/inference/cancellation"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/firstcontent"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

func (r *Race) WaitPrimary(ctx context.Context, current RaceAttempt, provider *registry.Provider, pr *registry.PendingRequest, backupChunkClosed bool) RaceResult {
	r.result = RaceResult{Attempt: current}
	return r.waitPrimary(ctx, provider, pr, backupChunkClosed)
}

func (r *Race) WaitBackup(ctx context.Context, current, backup RaceAttempt) RaceResult {
	r.result = RaceResult{Attempt: current}
	return r.waitBackup(ctx, backup)
}

// waitPrimary retains the bookkeeping distinctions between a backup terminal
// read from its closed chunk channel and one read directly from its error arm.
func (r *Race) waitPrimary(ctx context.Context, provider *registry.Provider, pr *registry.PendingRequest, backupChunkClosed bool) RaceResult {
	clock := r.config.Clock.ForPending(pr)
	primaryDeadline := clock.Timer(clock.Wait(r.config.Deadline - r.config.SpeculativeAt))
	defer func() { primaryDeadline.Stop() }()
	for {
		select {
		case chunk, ok := <-pr.ChunkCh:
			if ok && firstcontent.HoldPreContentBoilerplate(pr, chunk, &r.result.Attempt.HeldChunks) {
				clock.RearmExpired(&primaryDeadline)
				continue
			}
			primaryDeadline.Stop()
			if ok {
				r.commit(pr, chunk.Data)
			} else {
				select {
				case msg := <-pr.ErrorCh:
					r.exclude(provider)
					r.deps.CancelTerminal(provider, pr)
					r.setFailure(provider, msg)
					r.failedVersion(provider)
					if backupChunkClosed {
						r.recordFailure(pr, msg)
					}
					r.noteError(provider, pr, msg, &r.result.Attempt.HeldChunks, true)
					r.clearAttempt(backupChunkClosed)
					return r.finish(Retry)
				default:
				}
			}
			return r.finish(Committed)
		case <-pr.AcceptedCh:
			continue
		case msg := <-pr.ErrorCh:
			primaryDeadline.Stop()
			if r.commitReady(pr, msg) {
				return r.finish(Committed)
			}
			r.exclude(provider)
			r.deps.CancelTerminal(provider, pr)
			r.setFailure(provider, msg)
			r.failedVersion(provider)
			r.recordFailure(pr, msg)
			r.noteError(provider, pr, msg, &r.result.Attempt.HeldChunks, backupChunkClosed)
			r.clearAttempt(true)
			return r.finish(Retry)
		case <-primaryDeadline.C:
			if chunk, ok := firstcontent.DrainReadyFirstContent(pr, &r.result.Attempt.HeldChunks); ok {
				r.commit(pr, chunk.Data)
				return r.finish(Committed)
			}
			if pr.FirstContentIngressArrivedByDeadline() {
				continue
			}
			if len(r.result.Attempt.HeldChunks) > 0 && clock.CanExtendPreamble() {
				r.result.PreambleLiveness = true
				return r.finish(Accepted)
			}
			if !r.deps.CancelTimeout(provider, pr) {
				continue
			}
			r.exclude(provider)
			r.deps.Registry.RecordWarmPoolTTFTMiss(r.config.Model, clock.Duration(r.config.Deadline))
			if firstcontent.ProviderAttemptAttributableStall(pr, clock.Duration(r.config.Deadline)) {
				r.deps.Effects.RecordError(provider.ID, pr, http.StatusGatewayTimeout, "", "", "")
			}
			r.recordTimeout(pr)
			r.setTimeout("timeout waiting for first response")
			r.noteTimeout()
			r.clearAttempt(true)
			return r.finish(Retry)
		case <-ctx.Done():
			primaryDeadline.Stop()
			r.recordClientGone(pr)
			r.deps.Cancel(provider, pr, cancellation.CauseClientGonePre)
			r.deps.Refund()
			return r.finish(ClientGone)
		}
	}
}

func (r *Race) waitBackup(ctx context.Context, backup RaceAttempt) RaceResult {
	provider, pr := backup.Provider, backup.Pending
	// The primary is already gone. Attribute the survivor now, unless the
	// primary's deterministic terminal verdict froze the request-wide latch.
	r.noteServing(provider, pr)
	clock := r.config.Clock.ForPending(pr)
	backupDeadline := clock.Timer(clock.Wait(r.config.Deadline - r.config.SpeculativeAt))
	defer func() { backupDeadline.Stop() }()
	for {
		select {
		case chunk, ok := <-pr.ChunkCh:
			if ok && firstcontent.HoldPreContentBoilerplate(pr, chunk, &backup.HeldChunks) {
				clock.RearmExpired(&backupDeadline)
				continue
			}
			backupDeadline.Stop()
			if ok {
				pr.BackupWon.Store(true)
				r.result.Attempt = backup
				r.result.Attempt.RequestID = pr.RequestID
				r.commit(pr, chunk.Data)
			} else {
				select {
				case msg := <-pr.ErrorCh:
					r.exclude(provider)
					r.deps.CancelTerminal(provider, pr)
					r.setFailure(provider, msg)
					r.failedVersion(provider)
					r.recordFailure(pr, msg)
					r.noteError(provider, pr, msg, &backup.HeldChunks, true)
					r.clearAttempt(false)
					return r.finish(Retry)
				default:
					pr.BackupWon.Store(true)
					r.result.Attempt = backup
					r.result.Attempt.RequestID = pr.RequestID
				}
			}
			return r.finish(Committed)
		case <-pr.AcceptedCh:
			continue
		case msg := <-pr.ErrorCh:
			backupDeadline.Stop()
			if chunk, ok := firstcontent.DrainReadyFirstContent(pr, &backup.HeldChunks); ok {
				pr.BackupWon.Store(true)
				r.result.Attempt = backup
				r.result.Attempt.RequestID = pr.RequestID
				r.noteServing(provider, pr)
				r.commit(pr, chunk.Data)
				r.result.Content.InitialError = &msg
				return r.finish(Committed)
			}
			r.exclude(provider)
			r.deps.CancelTerminal(provider, pr)
			r.setFailure(provider, msg)
			r.failedVersion(provider)
			r.recordFailure(pr, msg)
			r.noteError(provider, pr, msg, &backup.HeldChunks, false)
			r.clearAttempt(false)
			return r.finish(Retry)
		case <-backupDeadline.C:
			if chunk, ok := firstcontent.DrainReadyFirstContent(pr, &backup.HeldChunks); ok {
				pr.BackupWon.Store(true)
				r.result.Attempt = backup
				r.result.Attempt.RequestID = pr.RequestID
				r.commit(pr, chunk.Data)
				return r.finish(Committed)
			}
			if pr.FirstContentIngressArrivedByDeadline() {
				continue
			}
			if len(backup.HeldChunks) > 0 && clock.CanExtendPreamble() {
				pr.BackupWon.Store(true)
				r.result.Attempt = backup
				r.result.Attempt.RequestID = pr.RequestID
				r.result.PreambleLiveness = true
				return r.finish(Accepted)
			}
			if !r.deps.CancelTimeout(provider, pr) {
				continue
			}
			r.exclude(provider)
			r.deps.Registry.RecordWarmPoolTTFTMiss(r.config.Model, clock.Duration(r.config.Deadline))
			if firstcontent.ProviderAttemptAttributableStall(pr, clock.Duration(r.config.Deadline-r.config.SpeculativeAt)) {
				r.deps.Effects.RecordError(provider.ID, pr, http.StatusGatewayTimeout, "", "", "")
			}
			r.recordTimeout(pr)
			r.setTimeout("timeout waiting for first response (backup)")
			r.noteTimeout()
			r.clearAttempt(false)
			return r.finish(Retry)
		case <-ctx.Done():
			backupDeadline.Stop()
			r.recordClientGone(pr)
			r.deps.Cancel(provider, pr, cancellation.CauseClientGonePre)
			r.deps.Refund()
			return r.finish(ClientGone)
		}
	}
}
