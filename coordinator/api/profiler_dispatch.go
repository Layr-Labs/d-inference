package api

// Dispatch-loop hooks for the system profiler: attempt lifecycle completion,
// first-content / commit stamps, and the additive X-Timing keys.

import (
	"encoding/json"
	"github.com/eigeninference/d-inference/coordinator/api/types"
	"github.com/eigeninference/d-inference/coordinator/inference/response"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"net/http"
)

func nonNegativeSegment(v int64, anomaly *bool) int64 {
	if v < 0 {
		*anomaly = true
		return 0
	}
	return v
}

// writeTimingHeaderWithProfile is writeTimingHeader plus the profiler's
// additive keys: the legacy keys keep their documented formulas (clamped at
// zero with timing_anomaly set when a retried attempt made one negative), the
// additive keys are derived from the attempt stamps. With the profiler off
// the header is byte-for-byte the legacy output.
func (d *dispatchState) writeTimingHeaderWithProfile(w http.ResponseWriter, pr *registry.PendingRequest) {
	tj := response.RequestTimingDetails(pr.Timing)
	if tj == nil {
		return
	}
	d.applyProfileTiming(tj, pr)
	if tjJSON, err := json.Marshal(tj); err == nil {
		w.Header().Set("X-Timing", string(tjJSON))
	}
}

// applyProfileTiming clamps the legacy segments and fills the additive keys.
func (d *dispatchState) applyProfileTiming(tj *types.RequestTimingDetails, pr *registry.PendingRequest) {
	// With the profiler off the header is byte-for-byte the legacy output.
	if tj == nil || d.profile == nil || d.profile.CompactOnly {
		return
	}
	anomaly := false
	tj.ParseUs = nonNegativeSegment(tj.ParseUs, &anomaly)
	tj.ReserveUs = nonNegativeSegment(tj.ReserveUs, &anomaly)
	tj.MediaFetchUs = nonNegativeSegment(tj.MediaFetchUs, &anomaly)
	tj.RouteUs = nonNegativeSegment(tj.RouteUs, &anomaly)
	tj.QueueUs = nonNegativeSegment(tj.QueueUs, &anomaly)
	tj.EncryptUs = nonNegativeSegment(tj.EncryptUs, &anomaly)
	tj.DispatchUs = nonNegativeSegment(tj.DispatchUs, &anomaly)
	tj.ProviderUs = nonNegativeSegment(tj.ProviderUs, &anomaly)
	tj.TimingAnomaly = anomaly

	rp := d.profile
	tj.PreHandlerUs = rp.HandlerEntryUS.Load()
	tj.PreflightUs = rp.PreflightUS
	ap := pr.Profile
	if ap == nil {
		return
	}
	diff := func(a, b registry.AttemptStamp) int64 {
		from, to := ap.Get(a), ap.Get(b)
		if from == 0 || to == 0 || to < from {
			return 0
		}
		return to - from
	}
	tj.RouteReserveUs = diff(registry.StampAttemptStart, registry.StampReserveDone)
	tj.QueuePureUs = diff(registry.StampQueued, registry.StampDequeued)
	tj.WriterUs = diff(registry.StampWriteSubmitted, registry.StampWriteDequeued)
	tj.SocketUs = diff(registry.StampWriteDequeued, registry.StampWriteDone)
	tj.ProviderAckUs = diff(registry.StampWriteDone, registry.StampAccepted)
}

// stampFirstContent records the first-content stamps on the committed attempt.
func (d *dispatchState) stampFirstContent(pr *registry.PendingRequest) {
	ap := pr.Profile
	if ap == nil {
		return
	}
	ap.Mark(registry.StampFirstChunkDequeued)
	ap.Mark(registry.StampFirstContent)
	if t := pr.FirstContentIngressAtSafe(); !t.IsZero() {
		ap.MarkAt(registry.StampFirstContentIngress, t)
	}
	d.profile.SetHeldPreambleChunks(len(d.heldChunks))
}

// stampCommitted marks the winning attempt and, for streams, the
// headers-written offset (the SSE headers go out right after commit). A
// non-streaming response writes its headers with the body later, in
// writeNonStreamBody, so its offset is stamped there instead.
func (d *dispatchState) stampCommitted(pr *registry.PendingRequest) {
	if rp := d.profile; rp != nil && d.stream {
		rp.Stamp(&rp.HeadersWrittenUS)
	}
	if ap := pr.Profile; ap != nil {
		ap.Winning.Store(true)
	}
}

// closeUndispatchedAttempt closes out an attempt that never reached the
// provider (reserve failed, queue wait ended, frame could not be written).
// Only the terminal half completes here; the handler half lands in
// finalizeProfile when the dispatch loop returns.
// Idempotent and nil-safe; a dispatched or winning attempt is left alone.
func closeUndispatchedAttempt(ap *registry.AttemptProfile, dispatchErr string, code int) {
	if ap == nil || ap.Finalized() || ap.Winning.Load() || ap.Dispatched() {
		return
	}
	status := "error"
	if code == http.StatusTooManyRequests || code == http.StatusServiceUnavailable || code == http.StatusGatewayTimeout {
		status = "rejected"
	}
	if code == 499 {
		status = "cancelled"
	}
	ap.SetOutcome(status, dispatchErrorClass(dispatchErr), "", "not_dispatched", "")
	// Only the terminal half closes here. The handler half is completed by
	// finalizeProfile once the dispatch loop returns, so the record is never
	// built (on the sink worker) while a later retry is still writing the
	// request-level fields of the shared RequestProfile.
	ap.CompleteTerminal()
}

// finalizeProfile runs when the dispatch loop returns. It marks the handler
// half of every attempt; the terminal half (provider terminal, synthetic
// terminal, or grace expiry) completes each record independently.
func (d *dispatchState) finalizeProfile() {
	rp := d.profile
	if rp == nil {
		return
	}
	clientOutcome := "completed"
	switch {
	case d.r != nil && d.r.Context().Err() != nil:
		rp.Stamp(&rp.ClientGoneUS)
		clientOutcome = "client_gone"
	case !d.committed:
		clientOutcome = "error_response"
	}
	for _, ap := range rp.Attempts() {
		ap.SetOutcome("", "", "", "", clientOutcome)
		ap.CompleteHandler()
	}
}

// stampClientGone records a client disconnect with its phase.
func (d *dispatchState) stampClientGone(phase string) {
	rp := d.profile
	if rp == nil {
		return
	}
	rp.Stamp(&rp.ClientGoneUS)
	rp.SetClientGonePhase(phase)
}
