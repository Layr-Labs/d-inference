package observation

import (
	"errors"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
)

// Only accepted bytes count; failed writes cannot claim a completed stream.
func TestRelayStampsCountOnlyWrittenBytes(t *testing.T) {
	rp := registry.NewRequestProfile(time.Now(), "c", nil, 0)
	rs := NewRelayStamps(rp)
	rs.Wrote(5, nil)
	rs.Wrote(7, nil)
	if got := rp.BytesOut.Load(); got != 12 || rp.ChunksOut.Load() != 2 || rp.FirstFlushUS.Load() == 0 {
		t.Fatalf("clean writes: bytes=%d chunks=%d first_flush=%d", got, rp.ChunksOut.Load(), rp.FirstFlushUS.Load())
	}
	rs.Wrote(0, errors.New("broken pipe"))
	if rp.BytesOut.Load() != 12 || rp.ChunksOut.Load() != 2 || !rp.ClientWriteErr.Load() {
		t.Fatalf("failed write must count nothing and flag client_write_err: bytes=%d chunks=%d err=%v", rp.BytesOut.Load(), rp.ChunksOut.Load(), rp.ClientWriteErr.Load())
	}
	rs.Wrote(3, errors.New("short")) // partial: the 3 accepted bytes count, the error is kept
	if rp.BytesOut.Load() != 15 || !rp.ClientWriteErr.Load() {
		t.Fatalf("short write: bytes=%d err=%v", rp.BytesOut.Load(), rp.ClientWriteErr.Load())
	}
	rs.Done()
	if rp.DoneFlushedUS.Load() != 0 || rp.LastFlushUS.Load() == 0 {
		t.Fatalf("done after a failed write must not claim done_flushed (done=%d last=%d)", rp.DoneFlushedUS.Load(), rp.LastFlushUS.Load())
	}
	clean := registry.NewRequestProfile(time.Now(), "c", nil, 0)
	cs := NewRelayStamps(clean)
	cs.Wrote(4, nil)
	cs.Done()
	if clean.DoneFlushedUS.Load() == 0 || clean.ClientWriteErr.Load() {
		t.Fatal("clean stream must stamp done_flushed")
	}
}

// Coalescing changes the write count, not the number of delivered SSE frames.
func TestRelayStampsCoalescedWriteCountsFrames(t *testing.T) {
	rp := registry.NewRequestProfile(time.Now(), "c", nil, 0)
	rs := NewRelayStamps(rp)
	rs.WroteFrames(3, 100, nil)
	if rp.ChunksOut.Load() != 3 || rp.BytesOut.Load() != 100 || rp.FirstFlushUS.Load() == 0 {
		t.Fatalf("coalesced write: chunks=%d bytes=%d first_flush=%d, want 3/100/stamped",
			rp.ChunksOut.Load(), rp.BytesOut.Load(), rp.FirstFlushUS.Load())
	}
	rs.WroteFrames(0, 0, nil) // an empty batch counts nothing
	rs.WroteFrames(2, 0, errors.New("broken pipe"))
	if rp.ChunksOut.Load() != 3 || rp.BytesOut.Load() != 100 || !rp.ClientWriteErr.Load() {
		t.Fatalf("failed coalesced write must count nothing and flag client_write_err: chunks=%d bytes=%d err=%v",
			rp.ChunksOut.Load(), rp.BytesOut.Load(), rp.ClientWriteErr.Load())
	}
	rs.WroteFrames(2, 10, errors.New("short")) // partial: accepted bytes and frames count, the error is kept
	if rp.ChunksOut.Load() != 5 || rp.BytesOut.Load() != 110 || !rp.ClientWriteErr.Load() {
		t.Fatalf("short coalesced write: chunks=%d bytes=%d err=%v",
			rp.ChunksOut.Load(), rp.BytesOut.Load(), rp.ClientWriteErr.Load())
	}
	rs.Wrote(4, nil)
	if rp.ChunksOut.Load() != 6 || rp.BytesOut.Load() != 114 {
		t.Fatalf("wrote after wroteFrames: chunks=%d bytes=%d, want 6/114", rp.ChunksOut.Load(), rp.BytesOut.Load())
	}
}
