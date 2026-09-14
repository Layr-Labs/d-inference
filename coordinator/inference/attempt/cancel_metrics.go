package attempt

import (
	"strconv"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
)

const (
	MetricCancelSent         = "inference.cancel_sent"
	MetricCancelSendFailed   = "inference.cancel_send_failed"
	MetricCancelToTerminalMs = "inference.cancel_to_terminal_ms"
	MetricCancelledTerminal  = "inference.cancelled_terminal"
	MetricCancelUnresolved   = "inference.cancel_unresolved"
	MetricZombieStreamCancel = "inference.zombie_stream_cancel"

	CancelTerminalComplete   = "complete"
	CancelTerminalError      = "error"
	CancelTerminalStrayChunk = "stray_chunk"

	CancelledOutcomeCompletePartial = "complete_partial"
	CancelledOutcomeErrorCancelled  = "error_cancelled"
	CancelledOutcomeErrorOther      = "error_other"
)

func modelTag(model string) string {
	if model == "" {
		return "unknown"
	}
	return model
}

func cancelLatencyMs(d time.Duration) float64 {
	if d < 0 {
		return 0
	}
	return float64(d) / float64(time.Millisecond)
}

// ResolveCancelledTerminal correlates a provider terminal that found no live
// pending record with the cancel the coordinator recorded for it. Metric-only:
// billing for a parked post-commit record still settles in the caller, and a
// pre-commit attempt was refunded when it was abandoned. Returns the entry so
// the caller can classify the terminal instead of logging it as unknown.
// inference.cancelled_terminal is tagged delivered:false when no cancel ever
// reached the provider writer (every enqueue failed): the provider finished
// on its own, and the cancel→terminal latency is not measured for it.
func (s Service) ResolveCancelledTerminal(requestID, terminal, outcome string, now time.Time) (Cancellation, bool) {
	e, ok := s.deps.Tracker.terminal(requestID)
	if !ok {
		return Cancellation{}, false
	}
	delivered := e.sent > 0
	if delivered {
		s.deps.Metrics.Histogram(MetricCancelToTerminalMs, cancelLatencyMs(now.Sub(e.firstSentAt)),
			[]string{"terminal:" + terminal, "model:" + modelTag(e.model), "cause:" + e.cause})
	}
	s.deps.Metrics.Incr(MetricCancelledTerminal, []string{"outcome:" + outcome, "cause:" + e.cause,
		"delivered:" + strconv.FormatBool(delivered)})
	return e, true
}

// CancelledErrorOutcome classifies an error terminal for a cancelled request.
func CancelledErrorOutcome(msg *protocol.InferenceErrorMessage) string {
	if msg == nil {
		return CancelledOutcomeErrorOther
	}
	if msg.StatusCode == 499 ||
		msg.FailureCode == protocol.FailureCodeCancelled ||
		msg.TerminalCause == TerminalCauseCancelled {
		return CancelledOutcomeErrorCancelled
	}
	return CancelledOutcomeErrorOther
}

// emitExpiredCancelEntries reports cancels that never got a terminal. One
// that delivered a cancel and produced subsequent stray chunks contributes
// its last chunk as the terminal (terminal:stray_chunk). Every other entry
// is counted unresolved —
// the provider honored the cancel silently, disconnected, or never saw it.
func (s Service) emitExpiredCancelEntries(expired []Cancellation) {
	for i := range expired {
		e := &expired[i]
		if e.sent > 0 && !e.lastStrayAt.IsZero() && !e.lastStrayAt.Before(e.firstSentAt) {
			s.deps.Metrics.Histogram(MetricCancelToTerminalMs, cancelLatencyMs(e.lastStrayAt.Sub(e.firstSentAt)),
				[]string{"terminal:" + CancelTerminalStrayChunk, "model:" + modelTag(e.model), "cause:" + e.cause})
			continue
		}
		s.deps.Metrics.Incr(MetricCancelUnresolved, []string{"cause:" + e.cause, "model:" + modelTag(e.model)})
	}
}
