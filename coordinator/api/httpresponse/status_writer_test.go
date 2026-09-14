package httpresponse

import (
	"bufio"
	"errors"
	"net"
	"net/http"
	"net/http/httptest"
	"reflect"
	"testing"
)

type statusWriterRecorder struct {
	header   http.Header
	statuses []int
}

func (w *statusWriterRecorder) Header() http.Header          { return w.header }
func (w *statusWriterRecorder) WriteHeader(code int)         { w.statuses = append(w.statuses, code) }
func (*statusWriterRecorder) Write(data []byte) (int, error) { return len(data), nil }

type statusWriterTransport struct {
	statusWriterRecorder
	flushes int
	conn    net.Conn
	buffer  *bufio.ReadWriter
	err     error
}

func (w *statusWriterTransport) Flush() { w.flushes++ }
func (w *statusWriterTransport) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	return w.conn, w.buffer, w.err
}

func TestStatusWriterRetainsFirstExplicitStatusAndForwardsAllHeaders(t *testing.T) {
	for _, initial := range []int{0, http.StatusOK} {
		underlying := &statusWriterRecorder{header: make(http.Header)}
		w := NewStatusWriter(underlying, initial)
		if w.Status() != initial || len(underlying.statuses) != 0 {
			t.Fatalf("constructor wrote a header or lost initial status: %d %+v", w.Status(), underlying.statuses)
		}
		w.Header().Set("X-Dispatch", "present")
		w.WriteHeader(http.StatusAccepted)
		w.WriteHeader(http.StatusBadGateway)
		if w.Status() != http.StatusAccepted || !reflect.DeepEqual(underlying.statuses, []int{http.StatusAccepted, http.StatusBadGateway}) {
			t.Fatalf("explicit status/forwarding changed: status=%d calls=%v", w.Status(), underlying.statuses)
		}
		if underlying.Header().Get("X-Dispatch") != "present" || w.Unwrap() != underlying {
			t.Fatal("wrapper lost the original writer or header map")
		}
	}
}

func TestStatusWriterImplicitWriteKeepsInitialObservation(t *testing.T) {
	for _, initial := range []int{0, http.StatusOK} {
		underlying := httptest.NewRecorder()
		w := NewStatusWriter(underlying, initial)
		if n, err := w.Write([]byte("body")); err != nil || n != 4 {
			t.Fatalf("Write = %d, %v", n, err)
		}
		if w.Status() != initial || underlying.Code != http.StatusOK || underlying.Body.String() != "body" {
			t.Fatalf("implicit write changed observations: captured=%d actual=%d body=%q", w.Status(), underlying.Code, underlying.Body.String())
		}
	}
}

func TestStatusWriterDelegatesTransportInterfaces(t *testing.T) {
	conn, peer := net.Pipe()
	defer conn.Close()
	defer peer.Close()
	buffer := bufio.NewReadWriter(bufio.NewReader(conn), bufio.NewWriter(conn))
	sentinel := errors.New("hijack failure")
	underlying := &statusWriterTransport{statusWriterRecorder: statusWriterRecorder{header: make(http.Header)}, conn: conn, buffer: buffer, err: sentinel}
	w := NewStatusWriter(underlying, 0)
	w.Flush()
	if err := http.NewResponseController(w).Flush(); err != nil {
		t.Fatal(err)
	}
	if underlying.flushes != 2 || w.Status() != 0 {
		t.Fatal("flush delegation changed status or count")
	}
	gotConn, gotBuffer, err := w.Hijack()
	if gotConn != conn || gotBuffer != buffer || err != sentinel {
		t.Fatal("hijack changed the underlying result")
	}
	plain := NewStatusWriter(&statusWriterRecorder{header: make(http.Header)}, 0)
	plain.Flush()
	gotConn, gotBuffer, err = plain.Hijack()
	if gotConn != nil || gotBuffer != nil || err == nil || err.Error() != "underlying ResponseWriter does not implement http.Hijacker" {
		t.Fatalf("unsupported hijack = %v, %v, %v", gotConn, gotBuffer, err)
	}
}
