package attempt

import (
	"context"
	"errors"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"strconv"
	"time"
)

// SendAbandonCancel is the cancel primitive for an abandon path whose pending
// record was removed elsewhere (post-commit defer, handleChunk's overflow and
// late-content aborts): it records the request for terminal correlation and
// zombie re-sends, counts the cause, and sends the frame.
func (s Service) SendAbandonCancel(provider *registry.Provider, requestID, model, cause string) {
	now := time.Now()
	_, expired := s.deps.Tracker.record(requestID, model, cause, now)
	s.emitExpiredCancelEntries(expired)
	s.SendRecordedCancel(provider, requestID, model, cause)
}

// SendRecordedCancel sends the cancel for a request already recorded in the
// zombie tracker. The send is marked and counted on inference.cancel_sent only
// once the frame was handed to the provider writer: a control lane that is
// full or a writer that has stopped delivered nothing, so the entry is kept
// unsent (sent == 0) for the next stray chunk to retry, and a terminal that
// arrives meanwhile is not reported as cancel-to-terminal.
func (s Service) SendRecordedCancel(provider *registry.Provider, requestID, model, cause string) {
	resendIndex, sent := s.deps.Tracker.send(requestID, func() bool {
		return s.SendCancel(provider, requestID)
	})
	if !sent {
		return
	}
	if resendIndex > 0 {
		// A stray chunk can deliver the first cancel while the abandon
		// path releases capacity. This frame is then a resend too.
		s.deps.Metrics.Incr(MetricZombieStreamCancel, []string{"resend_index:" + strconv.Itoa(resendIndex)})
		return
	}
	s.deps.Metrics.Incr(MetricCancelSent, []string{"cause:" + cause, "model:" + modelTag(model)})
}

// cancelSendFailureReason maps an EnqueueText error to a bounded tag value.
func cancelSendFailureReason(err error) string {
	switch {
	case errors.Is(err, registry.ErrProviderWriterQueueFull):
		return "queue_full"
	case errors.Is(err, registry.ErrProviderWriterStopped):
		return "writer_stopped"
	case errors.Is(err, context.DeadlineExceeded), errors.Is(err, context.Canceled):
		return "ctx"
	default:
		return "other"
	}
}

// StrayChunk handles a chunk for a request the coordinator no longer
// tracks. For a request the coordinator cancelled it is the expected tail of
// that cancel: the cancel is re-sent on the escalating zombie schedule (the
// provider treats duplicates as free) and the log line is rate-limited per
// provider. An id nobody abandoned is counted as an unknown frame and
// cancelled immediately.
func (s Service) StrayChunk(provider *registry.Provider, providerID, requestID string, now time.Time) {
	if now.IsZero() {
		now = time.Now()
	}
	res := s.deps.Tracker.strayChunk(requestID, now)
	s.emitExpiredCancelEntries(res.expired)
	if res.cause == CancelCauseStrayChunk {
		s.deps.UnknownFrame("chunk", provider)
	}
	// request_id stays out of the log: until it matches coordinator state it is
	// provider-controlled and an arbitrary log-exfiltration channel.
	if allow, suppressed := s.deps.Tracker.allowStrayWarn(providerID, now); allow {
		s.deps.Logger().Warn("chunk for unknown request",
			"provider_id", providerID,
			"suppressed", suppressed,
		)
	}
	if !res.send {
		return
	}
	resendIndex, sent := s.deps.Tracker.send(requestID, func() bool {
		return s.SendCancel(provider, requestID)
	})
	if !sent {
		return
	}
	if resendIndex < 0 {
		// Untracked (zero-value Server): the frame went out, nothing to count.
		return
	}
	if resendIndex == 0 {
		// First cancel DELIVERED for this id: cause stray_chunk when no abandon
		// path recorded one, or the abandon path's cause when its own send
		// never reached the writer (or lost this race by microseconds).
		s.deps.Metrics.Incr(MetricCancelSent, []string{"cause:" + res.cause, "model:" + modelTag(res.model)})
	}
	s.deps.Metrics.Incr(MetricZombieStreamCancel, []string{"resend_index:" + strconv.Itoa(resendIndex)})
}
