package api

// Dispatch-loop hooks for the system profiler: attempt lifecycle completion,
// first-content / commit stamps, and the additive X-Timing keys.

import (
	"encoding/json"
	"github.com/eigeninference/d-inference/coordinator/api/types"
	"net/http"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
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
	tj := requestTimingDetails(pr.Timing)
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
	if tj == nil || d.profile == nil {
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

// writeNonStreamBody writes a non-streaming 200 response body and stamps the
// egress offsets (first/last flush, bytes out) so non-stream rows carry the
// same egress waterfall as SSE relays. Output is byte-identical to writeJSON.
func writeNonStreamBody(w http.ResponseWriter, rp *registry.RequestProfile, v any) {
	body, err := json.Marshal(v)
	if err != nil {
		writeJSON(w, http.StatusOK, v)
		return
	}
	body = append(body, '\n')
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	if rp != nil {
		rp.Stamp(&rp.HeadersWrittenUS)
	}
	n, err := w.Write(body)
	if rp == nil {
		return
	}
	if n > 0 {
		rp.Stamp(&rp.FirstFlushUS)
		rp.Stamp(&rp.LastFlushUS)
		rp.ChunksOut.Add(1)
		rp.BytesOut.Add(int64(n))
	}
	if err != nil || n != len(body) {
		// Blocked, short or failed egress is reported, not disguised as done.
		rp.ClientWriteErr.Store(true)
		return
	}
	rp.Stamp(&rp.DoneFlushedUS)
}

// relayStamps is the per-stream bookkeeping the SSE relay loops feed.
type relayStamps struct {
	rp        *registry.RequestProfile
	lastFlush time.Time
}

func newRelayStamps(rp *registry.RequestProfile) *relayStamps {
	return &relayStamps{rp: rp}
}

// flushed records one chunk written + flushed to the client.
func (r *relayStamps) flushed(bytes int) { r.flushedFrames(bytes, 1) }

// flushedFrames records one client write that carried frames SSE frames: the
// coalesced chat relay writes a whole batch per call, the generic emitters
// one frame per call. chunks_out counts frames — one per client-visible SSE
// event — never writes or flushes, so a coalesced relay and a per-chunk relay
// report the same chunks_out for the same stream. max_chunk_gap_us is the
// longest gap between successive client writes, the gap the client actually
// observes (frames inside one batch have none).
func (r *relayStamps) flushedFrames(bytes, frames int) {
	if r == nil || r.rp == nil || bytes <= 0 {
		return
	}
	if frames < 1 {
		frames = 1
	}
	now := time.Now()
	rp := r.rp
	if rp.FirstFlushUS.Load() == 0 {
		rp.Stamp(&rp.FirstFlushUS)
	} else if !r.lastFlush.IsZero() {
		if gap := now.Sub(r.lastFlush).Microseconds(); gap > rp.MaxChunkGapUS.Load() {
			rp.MaxChunkGapUS.Store(gap)
		}
	}
	r.lastFlush = now
	rp.ChunksOut.Add(int64(frames))
	rp.BytesOut.Add(int64(bytes))
}

// done records the terminal [DONE] flush.
func (r *relayStamps) done() {
	if r == nil || r.rp == nil {
		return
	}
	r.rp.Stamp(&r.rp.LastFlushUS)
	// A stream whose write failed never completed its egress: leave
	// done_flushed_us absent so the row does not claim a terminal flush.
	if r.rp.ClientWriteErr.Load() {
		return
	}
	r.rp.Stamp(&r.rp.DoneFlushedUS)
}

// wrote records the outcome of one client write carrying a single frame: only
// bytes the ResponseWriter accepted count as flushed, and a failed or short
// write marks client_write_err so the record never claims output the client
// did not receive.
func (r *relayStamps) wrote(n int, err error) { r.wroteFrames(n, 1, err) }

// wroteFrames is wrote for a write that carried frames SSE frames (the
// coalesced chat relay). A write the client accepted at all (n > 0) credits
// every frame of the batch — mirroring the per-chunk form, where a partially
// accepted chunk still counted — and a failed write additionally marks
// client_write_err, which is what flags the row's egress as unreliable.
func (r *relayStamps) wroteFrames(n, frames int, err error) {
	if r == nil || r.rp == nil {
		return
	}
	if err != nil {
		r.writeErr()
	}
	if n > 0 {
		r.flushedFrames(n, frames)
	}
}

// writeErr records a failed client write.
func (r *relayStamps) writeErr() {
	if r == nil || r.rp == nil {
		return
	}
	r.rp.ClientWriteErr.Store(true)
}

// profileClientGone stamps a client disconnect observed by a relay loop that
// has only the pending request in hand.
func profileClientGone(pr *registry.PendingRequest, phase string) {
	if pr == nil || pr.Profile == nil {
		return
	}
	rp := pr.Profile.Parent()
	if rp == nil {
		return
	}
	rp.Stamp(&rp.ClientGoneUS)
	rp.SetClientGonePhase(phase)
}
