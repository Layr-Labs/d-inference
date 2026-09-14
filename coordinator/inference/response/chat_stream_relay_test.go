package response

import (
	"github.com/eigeninference/d-inference/coordinator/registry"
	"strings"
	"testing"
	"time"
)

// Frames whose total exceeds the cap go out in batches no larger than the cap,
// in order and byte-for-byte, the profile still counts every frame, and the
// buffer that carried them does not keep a backing array larger than the cap.
func TestChatStreamRelay_ByteCapFlushesBeforeAppendExceedsIt(t *testing.T) {
	w := newResponseCaptureWriter()
	rp := registry.NewRequestProfile(time.Now(), "c", nil, 0)
	relay := NewChatSink(&registry.PendingRequest{}, w, w, rp, nil)

	// 100 KiB frames against the 256 KiB cap: two fit, the third would
	// overflow and forces the flush before it is appended.
	frame := "data: " + strings.Repeat("x", 100<<10)
	const n = 7
	var want strings.Builder
	for i := 0; i < n; i++ {
		relay.Frame(frame)
		want.WriteString(frame + "\n\n")
	}
	if w.flushes != 3 || w.writes != 3 {
		t.Fatalf("after %d frames: %d writes / %d flushes, want 3 / 3 (two frames per batch, one pending)", n, w.writes, w.flushes)
	}
	relay.Flush()
	if w.flushes != 4 || w.writes != 4 {
		t.Fatalf("final flush: %d writes / %d flushes, want 4 / 4", w.writes, w.flushes)
	}
	if w.body.String() != want.String() {
		t.Fatalf("byte stream diverged: got %d bytes, want %d", w.body.Len(), want.Len())
	}
	if w.maxWrite > MaxBatchBytes {
		t.Fatalf("largest write = %d bytes, exceeds the %d-byte cap", w.maxWrite, MaxBatchBytes)
	}
	if got := relay.buf.Cap(); got > MaxBatchBytes {
		t.Fatalf("buffer retained %d bytes of capacity after the burst, want <= %d", got, MaxBatchBytes)
	}
	if rp.ChunksOut.Load() != n || rp.BytesOut.Load() != int64(want.Len()) {
		t.Fatalf("profile chunks_out=%d bytes_out=%d, want %d / %d", rp.ChunksOut.Load(), rp.BytesOut.Load(), n, want.Len())
	}
}

// A frame larger than the cap (a provider chunk near the 10 MiB read limit) is
// still relayed intact as one write — after the pending batch — and the buffer
// that held it is released rather than pinned for the rest of the stream.
func TestChatStreamRelay_OversizedFrameIsWrittenWholeAndReleased(t *testing.T) {
	w := newResponseCaptureWriter()
	relay := NewChatSink(&registry.PendingRequest{}, w, w, nil, nil)

	small := `data: {"a":1}`
	big := "data: " + strings.Repeat("y", 2*MaxBatchBytes)
	relay.Frame(small)
	relay.Frame(big)
	if w.writes != 1 || w.body.String() != small+"\n\n" {
		t.Fatalf("the pending frame must be flushed ahead of an oversized one: writes=%d body=%q", w.writes, w.body.String())
	}
	relay.Flush()
	want := small + "\n\n" + big + "\n\n"
	if w.writes != 2 || w.flushes != 2 || w.body.String() != want {
		t.Fatalf("oversized frame: %d writes / %d flushes, body %d bytes; want 2 / 2 / %d", w.writes, w.flushes, w.body.Len(), len(want))
	}
	if w.maxWrite != len(big)+2 {
		t.Fatalf("oversized frame was not written whole: largest write = %d, want %d", w.maxWrite, len(big)+2)
	}
	if got := relay.buf.Cap(); got != 0 {
		t.Fatalf("buffer retained %d bytes of capacity after an oversized batch, want released", got)
	}
	// The relay keeps working on a fresh buffer.
	relay.Frame(small)
	relay.Flush()
	if w.body.String() != want+small+"\n\n" {
		t.Fatalf("relay broken after releasing the buffer: %q", w.body.String())
	}
}
