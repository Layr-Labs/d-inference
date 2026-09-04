package api

import (
	"context"
	"errors"
	"strconv"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// Cancel causes: the bounded set of reasons the coordinator sends a WS cancel.
// A cancel is sent ONLY when the attempt's pending record still existed when
// it was abandoned — i.e. no provider terminal had been seen — so a provider
// error or a clean completion never produces one.
const (
	cancelCauseFirstChunkTimeout = "first_chunk_timeout"
	cancelCauseHedgeLoser        = "hedge_loser"
	cancelCauseClientGonePre     = "client_gone_pre"
	cancelCauseClientGonePost    = "client_gone_post"
	// cancelCauseStreamTimeout covers every other post-commit exit without a
	// terminal — the idle stream timeout in practice.
	cancelCauseStreamTimeout = "stream_timeout"
	cancelCauseOverflow      = "overflow"
	cancelCauseLateContent   = "late_content"
	// cancelCauseStrayChunk is a cancel triggered by a chunk for an id no
	// abandon path recorded (genuinely unknown, or predating a restart).
	cancelCauseStrayChunk = "stray_chunk"
)

const (
	metricCancelSent         = "inference.cancel_sent"
	metricCancelSendFailed   = "inference.cancel_send_failed"
	metricCancelToTerminalMs = "inference.cancel_to_terminal_ms"
	metricCancelledTerminal  = "inference.cancelled_terminal"
	metricCancelUnresolved   = "inference.cancel_unresolved"
	metricZombieStreamCancel = "inference.zombie_stream_cancel"

	cancelTerminalComplete   = "complete"
	cancelTerminalError      = "error"
	cancelTerminalStrayChunk = "stray_chunk"

	cancelledOutcomeCompletePartial = "complete_partial"
	cancelledOutcomeErrorCancelled  = "error_cancelled"
	cancelledOutcomeErrorOther      = "error_other"
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

// sendAbandonCancel is the cancel primitive for an abandon path whose pending
// record was removed elsewhere (handleChunk's overflow and late-content
// aborts): it records the request for terminal correlation and zombie
// re-sends, counts the cause, and sends the frame.
func (s *Server) sendAbandonCancel(provider *registry.Provider, pr *registry.PendingRequest, cause string) {
	if pr == nil {
		return
	}
	now := time.Now()
	_, expired := s.zombieCanceller.record(pr.RequestID, pr.Model, cause, now)
	s.emitExpiredCancelEntries(expired)
	s.sendRecordedCancel(provider, pr, cause, now)
}

// sendRecordedCancel sends the cancel for a request already recorded in the
// zombie tracker, marking the send so the re-send schedule is anchored. This
// is the ONE place the request profile's cancel stamp is taken: a stamp means
// a cancel frame for this attempt was really handed to the provider writer,
// never a phantom after a terminal.
func (s *Server) sendRecordedCancel(provider *registry.Provider, pr *registry.PendingRequest, cause string, now time.Time) {
	if pr == nil {
		return
	}
	s.zombieCanceller.markSent(pr.RequestID, now)
	pr.Profile.Mark(registry.StampCancelSent)
	s.ddIncr(metricCancelSent, []string{"cause:" + cause, "model:" + modelTag(pr.Model)})
	if !s.sendProviderCancel(provider, pr.RequestID) {
		s.zombieCanceller.noteSendFailed(pr.RequestID, now)
	}
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

// noteStrayChunk handles a chunk for a request the coordinator no longer
// tracks. For a request the coordinator cancelled it is the expected tail of
// that cancel: the cancel is re-sent on the escalating zombie schedule (the
// provider treats duplicates as free) and the log line is rate-limited per
// provider. An id nobody abandoned is counted as an unknown frame
// (inference.unknown_request_frames{kind:chunk}, the profiler's fleet
// counter) and cancelled immediately.
func (s *Server) noteStrayChunk(provider *registry.Provider, providerID, requestID string, now time.Time) {
	if now.IsZero() {
		now = time.Now()
	}
	res := s.zombieCanceller.strayChunk(requestID, now)
	s.emitExpiredCancelEntries(res.expired)
	if res.cause == cancelCauseStrayChunk {
		s.ddIncr("inference.unknown_request_frames", []string{"kind:chunk"})
		s.unknownRequestFrames.Add(1)
	}
	// request_id stays out of the log: until it matches coordinator state it is
	// provider-controlled and an arbitrary log-exfiltration channel.
	if allow, suppressed := s.zombieCanceller.allowStrayWarn(providerID, now); allow {
		s.logger.Warn("chunk for unknown request",
			"provider_id", providerID,
			"suppressed", suppressed,
		)
	}
	if !res.send {
		return
	}
	if res.resendIndex == 0 {
		// First cancel ever for this id (normally cause stray_chunk; an abandon
		// path's own send may also lose this race by microseconds).
		s.ddIncr(metricCancelSent, []string{"cause:" + res.cause, "model:" + modelTag(res.model)})
	}
	if !s.sendProviderCancel(provider, requestID) {
		s.zombieCanceller.noteSendFailed(requestID, now)
	}
	s.ddIncr(metricZombieStreamCancel, []string{"resend_index:" + strconv.Itoa(res.resendIndex)})
}

// resolveCancelledTerminal correlates a provider terminal that found no live
// pending record with the cancel the coordinator sent for it. Metric-only:
// billing for a parked post-commit record still settles in the caller, and a
// pre-commit attempt was refunded when it was abandoned. Returns the entry so
// the caller can classify the terminal instead of logging it as unknown.
func (s *Server) resolveCancelledTerminal(requestID, terminal, outcome string, now time.Time) (zombieEntry, bool) {
	e, ok := s.zombieCanceller.terminal(requestID)
	if !ok {
		return zombieEntry{}, false
	}
	s.ddHistogram(metricCancelToTerminalMs, cancelLatencyMs(now.Sub(e.firstCancelAt)),
		[]string{"terminal:" + terminal, "model:" + modelTag(e.model), "cause:" + e.cause})
	s.ddIncr(metricCancelledTerminal, []string{"outcome:" + outcome, "cause:" + e.cause})
	return e, true
}

// cancelledErrorOutcome classifies an error terminal for a cancelled request.
func cancelledErrorOutcome(msg *protocol.InferenceErrorMessage) string {
	if msg == nil {
		return cancelledOutcomeErrorOther
	}
	if msg.StatusCode == 499 ||
		msg.FailureCode == protocol.FailureCodeCancelled ||
		msg.TerminalCause == terminalCauseCancelled {
		return cancelledOutcomeErrorCancelled
	}
	return cancelledOutcomeErrorOther
}

// emitExpiredCancelEntries reports cancels that never got a terminal. One
// that produced stray chunks contributes its last chunk as the terminal
// (terminal:stray_chunk); one that produced nothing is counted unresolved —
// the provider honored the cancel silently, disconnected, or never saw it.
func (s *Server) emitExpiredCancelEntries(expired []zombieEntry) {
	for i := range expired {
		e := &expired[i]
		if !e.lastStrayAt.IsZero() {
			s.ddHistogram(metricCancelToTerminalMs, cancelLatencyMs(e.lastStrayAt.Sub(e.firstCancelAt)),
				[]string{"terminal:" + cancelTerminalStrayChunk, "model:" + modelTag(e.model), "cause:" + e.cause})
			continue
		}
		s.ddIncr(metricCancelUnresolved, []string{"cause:" + e.cause, "model:" + modelTag(e.model)})
	}
}
