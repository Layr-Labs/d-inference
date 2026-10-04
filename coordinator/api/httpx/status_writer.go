package httpx

import (
	"bufio"
	"errors"
	"net"
	"net/http"
)

// StatusWriter records the first explicit status and preserves the streaming
// and WebSocket interfaces of the existing transport wrapper.
type StatusWriter struct {
	http.ResponseWriter
	Status      int
	wroteHeader bool
}

func (sw *StatusWriter) WriteHeader(code int) {
	if !sw.wroteHeader {
		sw.Status = code
		sw.wroteHeader = true
	}
	sw.ResponseWriter.WriteHeader(code)
}

func (sw *StatusWriter) Flush() {
	if f, ok := sw.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}

func (sw *StatusWriter) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	if hj, ok := sw.ResponseWriter.(http.Hijacker); ok {
		return hj.Hijack()
	}
	return nil, nil, errors.New("underlying ResponseWriter does not implement http.Hijacker")
}

func (sw *StatusWriter) Unwrap() http.ResponseWriter { return sw.ResponseWriter }
