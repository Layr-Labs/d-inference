package api

// Byte-cap tests for the chat relay's coalesced batch (chatStreamRelay.buf):
// the batch is flushed before an append would push it past
// maxCoalescedBatchBytes, a backing array that outgrew the cap is released
// after the flush, and the consumer-visible byte stream is unchanged — the cap
// only moves flush boundaries.

import (
	"bytes"
	"net/http"
)

// capturingResponseWriter is countingResponseWriter plus the body itself and
// the size of the largest single Write, so a test can pin both the bytes on
// the wire and the batch size each write carried.
type capturingResponseWriter struct {
	countingResponseWriter
	body     bytes.Buffer
	maxWrite int
}

func newCapturingResponseWriter() *capturingResponseWriter {
	return &capturingResponseWriter{countingResponseWriter: countingResponseWriter{header: make(http.Header)}}
}

func (w *capturingResponseWriter) Write(p []byte) (int, error) {
	if len(p) > w.maxWrite {
		w.maxWrite = len(p)
	}
	w.body.Write(p)
	return w.countingResponseWriter.Write(p)
}
