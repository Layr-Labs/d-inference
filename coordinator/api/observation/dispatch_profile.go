package observation

import (
	"encoding/json"
	"github.com/eigeninference/d-inference/coordinator/api/httpx"
	"github.com/eigeninference/d-inference/coordinator/api/types"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"net/http"
	"time"
)

func nonNegativeSegment(v int64, anomaly *bool) int64 {
	if v < 0 {
		*anomaly = true
		return 0
	}
	return v
}

// applyProfileTiming clamps the legacy segments and fills the additive keys.
func ApplyProfileTiming(rp *registry.RequestProfile, tj *types.RequestTimingDetails, pr *registry.PendingRequest) {
	// With the profiler off the header is byte-for-byte the legacy output.
	if tj == nil || rp == nil || rp.CompactOnly {
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

// CloseUndispatchedAttempt closes out an attempt that never reached the
// provider (reserve failed, queue wait ended, frame could not be written).
// Only the terminal half completes here; the handler half lands in
// finalizeProfile when the dispatch loop returns.
// Idempotent and nil-safe; a dispatched or winning attempt is left alone.
func CloseUndispatchedAttempt(ap *registry.AttemptProfile, dispatchErr string, code int) {
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
	ap.SetOutcome(status, dispatchErr, "", "not_dispatched", "")
	// Only the terminal half closes here. The handler half is completed by
	// finalizeProfile once the dispatch loop returns, so the record is never
	// built (on the sink worker) while a later retry is still writing the
	// request-level fields of the shared RequestProfile.
	ap.CompleteTerminal()
}

// WriteNonStreamBody writes a non-streaming 200 response body and stamps the
// egress offsets (first/last flush, bytes out) so non-stream rows carry the
// same egress waterfall as SSE relays. Output is byte-identical to writeJSON.
func WriteNonStreamBody(w http.ResponseWriter, rp *registry.RequestProfile, v any) {
	body, err := json.Marshal(v)
	if err != nil {
		httpx.WriteJSON(w, http.StatusOK, v)
		return
	}
	body = append(body, '\n')
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	if rp != nil {
		rp.Stamp(&rp.HeadersWrittenUS)
	}
	n, err := w.Write(body)
	MarkContentWrite(w, GeneratedContentJSON(body), n, len(body), err)
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
		// Blocked, short or failed egress is reported, not disguised as Done.
		rp.ClientWriteErr.Store(true)
		return
	}
	rp.Stamp(&rp.DoneFlushedUS)
}

// RelayStamps is the per-stream bookkeeping the SSE relay loops feed.
type RelayStamps struct {
	rp        *registry.RequestProfile
	lastFlush time.Time
}

func NewRelayStamps(rp *registry.RequestProfile) *RelayStamps {
	return &RelayStamps{rp: rp}
}

// Flushed records one chunk written + Flushed to the client.
func (r *RelayStamps) Flushed(bytes int) {
	r.FlushedFrames(1, bytes)
}

// FlushedFrames records one client flush that carried frames SSE frames:
// chunks_out advances by the frame count (the relays coalesce already-queued
// chunks into one write, and the field keeps meaning "frames delivered"),
// bytes_out by the bytes accepted, and first_flush_us / max_chunk_gap_us are
// stamped per call: per flush in the chat relay (when the bytes reach the
// wire), per event write in the emitter relays (just ahead of their deferred
// Flush).
func (r *RelayStamps) FlushedFrames(frames, bytes int) {
	if r == nil || r.rp == nil || bytes <= 0 || frames <= 0 {
		return
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

// Done records the terminal [DONE] flush.
func (r *RelayStamps) Done() {
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

// Wrote records the outcome of one client write: only bytes the ResponseWriter
// accepted count as Flushed, and a failed or short write marks client_write_err
// so the record never claims output the client did not receive.
func (r *RelayStamps) Wrote(n int, err error) {
	if r == nil || r.rp == nil {
		return
	}
	if err != nil {
		r.WriteErr()
	}
	if n > 0 {
		r.Flushed(n)
	}
}

// WroteFrames records the outcome of one coalesced client write carrying
// frames SSE frames (the chat relay's flush): the same contract as Wrote,
// with chunks_out advancing by the number of frames folded into the write.
func (r *RelayStamps) WroteFrames(frames, n int, err error) {
	if r == nil || r.rp == nil {
		return
	}
	if err != nil {
		r.WriteErr()
	}
	if n > 0 {
		r.FlushedFrames(frames, n)
	}
}

// WriteErr records a failed client write.
func (r *RelayStamps) WriteErr() {
	if r == nil || r.rp == nil {
		return
	}
	r.rp.ClientWriteErr.Store(true)
}

// ProfileClientGone stamps a client disconnect observed by a relay loop that
// has only the pending request in hand.
func ProfileClientGone(pr *registry.PendingRequest, phase string) {
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
