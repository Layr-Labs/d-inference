package response

import (
	"encoding/json"
	"github.com/eigeninference/d-inference/coordinator/api/httpresponse"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"net/http"
	"time"
)

// writeNonStreamBody writes a non-streaming 200 response body and stamps the
// egress offsets (first/last flush, bytes out) so non-stream rows carry the
// same egress waterfall as SSE relays. Output is byte-identical to writeJSON.
func (s *Writer) Body(w http.ResponseWriter, rp *registry.RequestProfile, v any) {
	body, err := json.Marshal(v)
	if err != nil {
		httpresponse.WriteJSON(w, http.StatusOK, v)
		return
	}
	body = append(body, '\n')
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusOK)
	if rp != nil {
		rp.Stamp(&rp.HeadersWrittenUS)
	}
	n, err := w.Write(body)
	observeContentWrite(s.deps.Observer, w, GeneratedContentJSON(body), n, len(body), err)
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
func (r *relayStamps) flushed(bytes int) {
	r.flushedFrames(1, bytes)
}

// flushedFrames records one client flush that carried frames SSE frames:
// chunks_out advances by the frame count (the relays coalesce already-queued
// chunks into one write, and the field keeps meaning "frames delivered"),
// bytes_out by the bytes accepted, and first_flush_us / max_chunk_gap_us are
// stamped per call: per flush in the chat relay (when the bytes reach the
// wire), per event write in the emitter relays (just ahead of their deferred
// Flush).
func (r *relayStamps) flushedFrames(frames, bytes int) {
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

// wrote records the outcome of one client write: only bytes the ResponseWriter
// accepted count as flushed, and a failed or short write marks client_write_err
// so the record never claims output the client did not receive.
func (r *relayStamps) wrote(n int, err error) {
	if r == nil || r.rp == nil {
		return
	}
	if err != nil {
		r.writeErr()
	}
	if n > 0 {
		r.flushed(n)
	}
}

// wroteFrames records the outcome of one coalesced client write carrying
// frames SSE frames (the chat relay's flush): the same contract as wrote,
// with chunks_out advancing by the number of frames folded into the write.
func (r *relayStamps) wroteFrames(frames, n int, err error) {
	if r == nil || r.rp == nil {
		return
	}
	if err != nil {
		r.writeErr()
	}
	if n > 0 {
		r.flushedFrames(frames, n)
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
