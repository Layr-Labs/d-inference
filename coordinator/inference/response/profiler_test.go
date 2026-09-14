package response

import (
	"errors"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"testing"
	"time"
)

// TestRelayStampsCountOnlyWrittenBytes pins the egress accounting contract:
// only bytes the ResponseWriter accepted are flushed, a failed write marks
// client_write_err, and a stream whose write failed never claims done.
func TestRelayStampsCountOnlyWrittenBytes(t *testing.T) {
	rp := registry.NewRequestProfile(time.Now(), "c", nil, 0)
	rs := newRelayStamps(rp)
	rs.wrote(5, nil)
	rs.wrote(7, nil)
	if got := rp.BytesOut.Load(); got != 12 || rp.ChunksOut.Load() != 2 || rp.FirstFlushUS.Load() == 0 {
		t.Fatalf("clean writes: bytes=%d chunks=%d first_flush=%d", got, rp.ChunksOut.Load(), rp.FirstFlushUS.Load())
	}
	rs.wrote(0, errors.New("broken pipe"))
	if rp.BytesOut.Load() != 12 || rp.ChunksOut.Load() != 2 || !rp.ClientWriteErr.Load() {
		t.Fatalf("failed write must count nothing and flag client_write_err: bytes=%d chunks=%d err=%v", rp.BytesOut.Load(), rp.ChunksOut.Load(), rp.ClientWriteErr.Load())
	}
	rs.wrote(3, errors.New("short")) // partial: the 3 accepted bytes count, the error is kept
	if rp.BytesOut.Load() != 15 || !rp.ClientWriteErr.Load() {
		t.Fatalf("short write: bytes=%d err=%v", rp.BytesOut.Load(), rp.ClientWriteErr.Load())
	}
	rs.done()
	if rp.DoneFlushedUS.Load() != 0 || rp.LastFlushUS.Load() == 0 {
		t.Fatalf("done after a failed write must not claim done_flushed (done=%d last=%d)", rp.DoneFlushedUS.Load(), rp.LastFlushUS.Load())
	}
	clean := registry.NewRequestProfile(time.Now(), "c", nil, 0)
	cs := newRelayStamps(clean)
	cs.wrote(4, nil)
	cs.done()
	if clean.DoneFlushedUS.Load() == 0 || clean.ClientWriteErr.Load() {
		t.Fatal("clean stream must stamp done_flushed")
	}
}

// TestRelayStampsCoalescedWriteCountsFrames pins the contract the chat relay's
// batched flush relies on: one client write carrying several SSE frames
// advances chunks_out by the frame count (the field keeps meaning "frames
// delivered" whether or not chunks were coalesced), bytes_out by the accepted
// bytes only, and a failed write flags client_write_err exactly as wrote does.
func TestRelayStampsCoalescedWriteCountsFrames(t *testing.T) {
	rp := registry.NewRequestProfile(time.Now(), "c", nil, 0)
	rs := newRelayStamps(rp)
	rs.wroteFrames(3, 100, nil)
	if rp.ChunksOut.Load() != 3 || rp.BytesOut.Load() != 100 || rp.FirstFlushUS.Load() == 0 {
		t.Fatalf("coalesced write: chunks=%d bytes=%d first_flush=%d, want 3/100/stamped",
			rp.ChunksOut.Load(), rp.BytesOut.Load(), rp.FirstFlushUS.Load())
	}
	rs.wroteFrames(0, 0, nil) // an empty batch (relay.flush with nothing buffered) counts nothing
	rs.wroteFrames(2, 0, errors.New("broken pipe"))
	if rp.ChunksOut.Load() != 3 || rp.BytesOut.Load() != 100 || !rp.ClientWriteErr.Load() {
		t.Fatalf("failed coalesced write must count nothing and flag client_write_err: chunks=%d bytes=%d err=%v",
			rp.ChunksOut.Load(), rp.BytesOut.Load(), rp.ClientWriteErr.Load())
	}
	rs.wroteFrames(2, 10, errors.New("short")) // partial: the accepted bytes and the frames count, the error is kept
	if rp.ChunksOut.Load() != 5 || rp.BytesOut.Load() != 110 || !rp.ClientWriteErr.Load() {
		t.Fatalf("short coalesced write: chunks=%d bytes=%d err=%v",
			rp.ChunksOut.Load(), rp.BytesOut.Load(), rp.ClientWriteErr.Load())
	}
	// wrote stays the one-frame case of the same accounting.
	rs.wrote(4, nil)
	if rp.ChunksOut.Load() != 6 || rp.BytesOut.Load() != 114 {
		t.Fatalf("wrote after wroteFrames: chunks=%d bytes=%d, want 6/114", rp.ChunksOut.Load(), rp.BytesOut.Load())
	}
}

// TestChatStreamRelayFlushReportsFramesAndBytes pins the relay side of the
// same contract: flush records the number of frames in the batch and the bytes
// the ResponseWriter accepted in the request profile, in one write and one
// Flush, and an empty batch neither writes nor flushes.
func TestChatStreamRelayFlushReportsFramesAndBytes(t *testing.T) {
	w := newResponseCaptureWriter()
	rp := registry.NewRequestProfile(time.Now(), "c", nil, 0)
	relay := NewChatSink(&registry.PendingRequest{}, w, w, rp, nil)
	relay.Frame(`data: {"a":1}`)
	relay.Frame(`data: {"b":2}`)
	relay.Frame("data: [DONE]")
	relay.Flush()
	want := "data: {\"a\":1}\n\ndata: {\"b\":2}\n\ndata: [DONE]\n\n"
	if w.body.String() != want || w.writes != 1 || w.flushes != 1 {
		t.Fatalf("flush wrote %q in %d write(s) / %d flush(es); want %q in 1 / 1",
			w.body.String(), w.writes, w.flushes, want)
	}
	if rp.ChunksOut.Load() != 3 || rp.BytesOut.Load() != int64(len(want)) || rp.ClientWriteErr.Load() {
		t.Fatalf("profile chunks_out=%d bytes_out=%d client_write_err=%v; want 3 / %d / false",
			rp.ChunksOut.Load(), rp.BytesOut.Load(), rp.ClientWriteErr.Load(), len(want))
	}
	relay.Flush()
	if w.writes != 1 || w.flushes != 1 || rp.ChunksOut.Load() != 3 || rp.BytesOut.Load() != int64(len(want)) {
		t.Fatalf("empty flush must neither write nor flush nor count: writes=%d flushes=%d chunks_out=%d bytes_out=%d",
			w.writes, w.flushes, rp.ChunksOut.Load(), rp.BytesOut.Load())
	}
}
