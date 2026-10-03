package api

// Flush/write accounting for the streaming relay. A counting ResponseWriter
// drives each streaming variant directly with a PendingRequest whose chunk
// channel is already full (the worst case for per-chunk flushing: every chunk
// is ready the moment the relay wakes), so the benchmark reports how many
// Flush() syscalls and Write() calls a 200-chunk burst costs.

import (
	"net/http"
)

// countingResponseWriter records writes and flushes without buffering the
// body (the bytes themselves are discarded; only counts matter here).
type countingResponseWriter struct {
	header  http.Header
	status  int
	writes  int
	bytes   int
	flushes int
}

func (w *countingResponseWriter) Header() http.Header  { return w.header }
func (w *countingResponseWriter) WriteHeader(code int) { w.status = code }
func (w *countingResponseWriter) Write(p []byte) (int, error) {
	w.writes++
	w.bytes += len(p)
	return len(p), nil
}
func (w *countingResponseWriter) Flush() { w.flushes++ }
