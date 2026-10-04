package inference

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/inference/attempt"
	firstcontent "github.com/eigeninference/d-inference/coordinator/internal/inference/firstcontent"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// commitReadyFirstContent gives an already-buffered, on-time content chunk
// precedence over a concurrently ready terminal channel. Provider websocket
// frames are read in order, but Go select does not preserve ordering across
// ChunkCh and ErrorCh.
func (d *dispatchState) commitReadyFirstContent(
	pr *registry.PendingRequest,
	held *[]string,
	errMsg protocol.InferenceErrorMessage,
) bool {
	content := d.s.NewContentCommitter().Buffered(d.profile, pr, held, errMsg)
	if content == nil {
		return false
	}
	d.firstChunk = content.FirstChunk
	d.committed = true
	d.initialError = content.InitialError
	return true
}

func (d *dispatchState) firstContentClock() firstcontent.Clock {
	receivedAt := time.Time{}
	if d.timing != nil {
		receivedAt = d.timing.ReceivedAt
	}
	return firstcontent.NewClock(receivedAt, d.deadline, d.speculativeAt)
}

func (d *dispatchState) firstTokenExpired() bool {
	return d != nil && d.firstContentClock().ForPending(d.pr).Expired()
}

// abandonInflightForFirstTokenTimeout cancels a request already on the wire
// when the request-absolute first-token clock is gone. Without this the
// exhausted ladder refunds the client while the provider keeps generating,
// retains the slot, and can later settle an already-rejected request. The
// terminal cause is OUR clock, so the last error is overridden with the
// synthetic 504 the exhausted ladder reclassifies to a retryable 429
// (first_chunk_timeout) — never a leaked 5xx from a prior attempt.
func (d *dispatchState) abandonInflightForFirstTokenTimeout() bool {
	if d == nil {
		return true
	}
	result := d.s.NewInflightAbandon(attempt.TimeoutConfig{
		Model: d.model, Provider: d.provider, Pending: d.pr,
		RequestID: d.requestID, Attempt: d.attempt,
	}).Run(d.firstContentClock().ForPending(d.pr).Duration(d.deadline))
	d.provider, d.pr = result.Provider, result.Pending
	if !result.Claimed {
		return false
	}
	d.setLastError(result.Failure.Message.Error, result.Failure.Message.StatusCode)
	if result.ExcludedProviderID != "" {
		d.excludeProviders[result.ExcludedProviderID] = struct{}{}
	}
	return true
}
