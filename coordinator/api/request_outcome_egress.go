package api

import (
	"github.com/eigeninference/d-inference/coordinator/inference/response"
	"net/http"
	"strings"
)

// outcomeWriter observes only locally accepted writes. It retains no response
// bytes. Content is marked at semantic relay/body call sites, never inferred
// from headers, preambles, an arbitrary HTTP 200, or a partial Write.
type outcomeWriter struct {
	http.ResponseWriter
	outcome      *requestOutcome
	status       int
	writeFailed  bool
	jsonResponse bool
}

func (w *outcomeWriter) Unwrap() http.ResponseWriter { return w.ResponseWriter }
func (w *outcomeWriter) WriteHeader(code int) {
	// A rejected status (or another pre-commit panic) may still be recovered
	// into a 500. Record only after the underlying writer accepts the header.
	jsonResponse := strings.HasPrefix(w.Header().Get("Content-Type"), "application/json")
	w.ResponseWriter.WriteHeader(code)
	if w.status == 0 && code >= 200 {
		w.status = code
		w.jsonResponse = jsonResponse
	}
}
func (w *outcomeWriter) Write(b []byte) (int, error) {
	if w.status == 0 {
		w.status = 200
		w.jsonResponse = strings.HasPrefix(w.Header().Get("Content-Type"), "application/json")
	}
	n, err := w.ResponseWriter.Write(b)
	if err != nil || n != len(b) {
		w.writeFailed = true
	}
	if w.jsonResponse {
		markResponseTerminalWrite(w, response.ResponseBodyTerminals(b), n, len(b), err)
	}
	return n, err
}
func (w *outcomeWriter) Flush() {
	if w.status == 0 {
		w.status = 200
		w.jsonResponse = strings.HasPrefix(w.Header().Get("Content-Type"), "application/json")
	}
	if f, ok := w.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}
func outcomeForWriter(w http.ResponseWriter) *requestOutcome {
	for w != nil {
		if ow, ok := w.(*outcomeWriter); ok {
			return ow.outcome
		}
		if sw, ok := w.(*sealingResponseWriter); ok {
			w = sw.inner
			continue
		}
		u, ok := w.(interface{ Unwrap() http.ResponseWriter })
		if !ok {
			return nil
		}
		w = u.Unwrap()
	}
	return nil
}
func markContentWrite(w http.ResponseWriter, content bool, n, expected int, err error) {
	if !content || err != nil || n != expected {
		return
	}
	if _, sealed := w.(*sealingResponseWriter); sealed {
		return
	}
	if o := outcomeForWriter(w); o != nil {
		o.mu.Lock()
		o.record.ContentWriteCompleted = true
		o.mu.Unlock()
	}
}

func markEgressError(w http.ResponseWriter) {
	if o := outcomeForWriter(w); o != nil {
		o.mu.Lock()
		o.record.EgressError = true
		o.mu.Unlock()
	}
}
