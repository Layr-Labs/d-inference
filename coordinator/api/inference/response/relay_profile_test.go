package response

import (
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/observation"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// Flush reports all accepted frames and bytes; an empty batch does no work.
func TestChatStreamRelayFlushReportsFramesAndBytes(t *testing.T) {
	w := newCapturingResponseWriter()
	rp := registry.NewRequestProfile(time.Now(), "c", nil, 0)
	relay := NewChatStreamRelay(&registry.PendingRequest{}, w, w, observation.NewRelayStamps(rp))
	relay.WriteFrame(`data: {"a":1}`)
	relay.WriteFrame(`data: {"b":2}`)
	relay.WriteFrame("data: [DONE]")
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
