package cancellation

import (
	"context"
	"errors"
	"strconv"
	"time"

	failure "github.com/eigeninference/d-inference/coordinator/internal/inference/failure"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// Cancel causes: the bounded set of reasons the coordinator sends a WS cancel.
// A cancel is sent ONLY when the attempt's pending record still existed when
// it was abandoned — i.e. no provider terminal had been seen — so a provider
// error or a clean completion never produces one.
const (
	CauseFirstChunkTimeout = "first_chunk_timeout"
	CauseHedgeLoser        = "hedge_loser"
	CauseClientGonePre     = "client_gone_pre"
	CauseClientGonePost    = "client_gone_post"
	// cancelCauseStreamTimeout covers every other post-commit exit without a
	// terminal — the idle stream timeout in practice.
	CauseStreamTimeout = "stream_timeout"
	CauseOverflow      = "overflow"
	CauseLateContent   = "late_content"
	// cancelCauseStrayChunk is a cancel triggered by a chunk for an id no
	// abandon path recorded (genuinely unknown, or predating a restart).
	CauseStrayChunk = "stray_chunk"
)

const (
	MetricCancelSent         = "inference.cancel_sent"
	MetricCancelSendFailed   = "inference.cancel_send_failed"
	MetricCancelToTerminalMs = "inference.cancel_to_terminal_ms"
	MetricCancelledTerminal  = "inference.cancelled_terminal"
	MetricCancelUnresolved   = "inference.cancel_unresolved"
	MetricZombieStreamCancel = "inference.zombie_stream_cancel"

	TerminalComplete   = "complete"
	TerminalError      = "error"
	TerminalStrayChunk = "stray_chunk"

	OutcomeCompletePartial = "complete_partial"
	OutcomeErrorCancelled  = "error_cancelled"
	OutcomeErrorOther      = "error_other"
)

func modelTag(Model string) string {
	if Model == "" {
		return "unknown"
	}
	return Model
}

func cancelLatencyMs(d time.Duration) float64 {
	if d < 0 {
		return 0
	}
	return float64(d) / float64(time.Millisecond)
}

// sendAbandonCancel is the cancel primitive for an abandon path whose pending
// record was removed elsewhere (post-commit defer, handleChunk's overflow and
// late-content aborts): it records the request for terminal correlation and
// zombie re-sends, counts the cause, and sends the frame.
func (s *Controller) SendAbandonCancel(provider *registry.Provider, requestID, Model, Cause string) {
	now := time.Now()
	_, Expired := s.Tracker.
		Record(requestID, Model, Cause, now)
	s.EmitExpiredCancelEntries(Expired)
	s.SendRecordedCancel(provider, requestID, Model, Cause)
}

// sendRecordedCancel sends the cancel for a request already recorded in the
// zombie tracker. The send is marked and counted on inference.cancel_sent only
// once the frame was handed to the provider writer: a control lane that is
// full or a writer that has stopped delivered nothing, so the entry is kept
// unsent (sent == 0) for the next stray chunk to retry, and a terminal that
// arrives meanwhile is not reported as cancel-to-terminal.
func (s *Controller) SendRecordedCancel(provider *registry.Provider, requestID, Model, Cause string) {
	ResendIndex, Sent := s.Tracker.
		Send(requestID, func() bool {
			return s.SendProviderCancel(provider, requestID)
		})
	if !Sent {
		return
	}
	if ResendIndex > 0 {
		s.Observation.

			// A stray chunk can deliver the first cancel while the abandon
			// path releases capacity. This frame is then a resend too.
			Incr(MetricZombieStreamCancel, []string{"resend_index:" + strconv.Itoa(ResendIndex)})
		return
	}
	s.Observation.
		Incr(MetricCancelSent, []string{"cause:" + Cause, "model:" + modelTag(Model)})
}

// cancelSendFailureReason maps an EnqueueText error to a bounded tag value.
func SendFailureReason(err error) string {
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

// noteStrayChunk handles a chunk for a request the coordinator no longer
// tracks. For a request the coordinator cancelled it is the expected tail of
// that cancel: the cancel is re-sent on the escalating zombie schedule (the
// provider treats duplicates as free) and the log line is rate-limited per
// provider. An id nobody abandoned is counted as an unknown frame and
// cancelled immediately.
func (s *Controller) NoteStrayChunk(provider *registry.Provider, providerID, requestID string, now time.Time) {
	if now.IsZero() {
		now = time.Now()
	}
	res := s.Tracker.
		StrayChunk(requestID, now)
	s.EmitExpiredCancelEntries(res.Expired)
	if res.Cause == CauseStrayChunk {
		s.EmitUnknownFrame(UnknownFrameKindChunk, provider)
	}
	// request_id stays out of the log: until it matches coordinator state it is
	// provider-controlled and an arbitrary log-exfiltration channel.
	if allow, suppressed := s.Tracker.
		AllowStrayWarn(providerID, now); allow {
		s.Logger.
			Warn("chunk for unknown request",
				"provider_id", providerID,
				"suppressed", suppressed,
			)
	}
	if !res.Send {
		return
	}
	ResendIndex, Sent := s.Tracker.
		Send(requestID, func() bool {
			return s.SendProviderCancel(provider, requestID)
		})
	if !Sent {
		return
	}
	if ResendIndex < 0 {
		// Untracked (zero-value Server): the frame went out, nothing to count.
		return
	}
	if ResendIndex == 0 {
		s.Observation.

			// First cancel DELIVERED for this id: cause stray_chunk when no abandon
			// path recorded one, or the abandon path's cause when its own send
			// never reached the writer (or lost this race by microseconds).
			Incr(MetricCancelSent, []string{"cause:" + res.Cause, "model:" + modelTag(res.Model)})
	}
	s.Observation.
		Incr(MetricZombieStreamCancel, []string{"resend_index:" + strconv.Itoa(ResendIndex)})
}

// resolveCancelledTerminal correlates a provider terminal that found no live
// pending record with the cancel the coordinator recorded for it. Metric-only:
// billing for a parked post-commit record still settles in the caller, and a
// pre-commit attempt was refunded when it was abandoned. Returns the entry so
// the caller can classify the terminal instead of logging it as unknown.
// inference.cancelled_terminal is tagged delivered:false when no cancel ever
// reached the provider writer (every enqueue failed): the provider finished
// on its own, and the cancel→terminal latency is not measured for it.
func (s *Controller) ResolveCancelledTerminal(requestID, Terminal, outcome string, now time.Time) (Entry, bool) {
	e, ok := s.Tracker.
		Terminal(requestID)
	if !ok {
		return Entry{}, false
	}
	delivered := e.Sent > 0
	if delivered {
		s.Observation.
			Histogram(MetricCancelToTerminalMs, cancelLatencyMs(now.Sub(e.FirstSentAt)),
				[]string{"terminal:" + Terminal, "model:" + modelTag(e.Model), "cause:" + e.Cause})
	}
	s.Observation.
		Incr(MetricCancelledTerminal, []string{"outcome:" + outcome, "cause:" + e.Cause,
			"delivered:" + strconv.FormatBool(delivered)})
	return e, true
}

// cancelledErrorOutcome classifies an error terminal for a cancelled request.
func ErrorOutcome(msg *protocol.InferenceErrorMessage) string {
	if msg == nil {
		return OutcomeErrorOther
	}
	if msg.StatusCode == 499 ||
		msg.FailureCode == protocol.FailureCodeCancelled ||
		msg.TerminalCause == failure.TerminalCauseCancelled {
		return OutcomeErrorCancelled
	}
	return OutcomeErrorOther
}

// emitExpiredCancelEntries reports cancels that never got a terminal. One
// that delivered a cancel and produced subsequent stray chunks contributes
// its last chunk as the terminal (terminal:stray_chunk). Every other entry
// is counted unresolved —
// the provider honored the cancel silently, disconnected, or never saw it.
func (s *Controller) EmitExpiredCancelEntries(Expired []Entry) {
	for i := range Expired {
		e := &Expired[i]
		if e.Sent > 0 && !e.LastStrayAt.IsZero() && !e.LastStrayAt.Before(e.FirstSentAt) {
			s.Observation.
				Histogram(MetricCancelToTerminalMs, cancelLatencyMs(e.LastStrayAt.Sub(e.FirstSentAt)),
					[]string{"terminal:" + TerminalStrayChunk, "model:" + modelTag(e.Model), "cause:" + e.Cause})
			continue
		}
		s.Observation.
			Incr(MetricCancelUnresolved, []string{"cause:" + e.Cause, "model:" + modelTag(e.Model)})
	}
}
