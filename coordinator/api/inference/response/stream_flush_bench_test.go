package response

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

func (w *countingResponseWriter) Header() http.Header { return w.header }

func (w *countingResponseWriter) WriteHeader(code int) { w.status = code }

func (w *countingResponseWriter) Write(p []byte) (int, error) {
	w.writes++
	w.bytes += len(p)
	return len(p), nil
}

func (w *countingResponseWriter) Flush() { w.flushes++ }
