package httpresponse

import (
	"bufio"
	"errors"
	"net"
	"net/http"
)

// StatusWriter wraps http.ResponseWriter to capture the status code
// for logging. It also implements http.Flusher and http.Hijacker by
// delegating to the underlying writer, which is required for SSE
// streaming and WebSocket upgrade respectively.
type StatusWriter struct {
	http.ResponseWriter
	status      int
	wroteHeader bool
}

func (sw *StatusWriter) WriteHeader(code int) {
	if !sw.wroteHeader {
		sw.status = code
		sw.wroteHeader = true
	}
	sw.ResponseWriter.WriteHeader(code)
}

func (sw *StatusWriter) Flush() {
	if f, ok := sw.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}

// Hijack implements http.Hijacker by delegating to the underlying writer.
// This is required for WebSocket upgrade to work through middleware.
func (sw *StatusWriter) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	if hj, ok := sw.ResponseWriter.(http.Hijacker); ok {
		return hj.Hijack()
	}
	return nil, nil, errors.New("underlying ResponseWriter does not implement http.Hijacker")
}

// Unwrap returns the underlying ResponseWriter, allowing the http package
// and websocket libraries to discover interfaces like http.Hijacker.
func (sw *StatusWriter) Unwrap() http.ResponseWriter {
	return sw.ResponseWriter
}

// NewStatusWriter sets the initial observed status without writing a header.
func NewStatusWriter(w http.ResponseWriter, status int) *StatusWriter {
	return &StatusWriter{ResponseWriter: w, status: status}
}

// Status returns the first explicit response status or its initial value.
func (sw *StatusWriter) Status() int { return sw.status }
