package providerwriter

import (
	"context"
	"errors"
	"fmt"
	"io"
	"math/rand"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"nhooyr.io/websocket"
)

const (
	// stallSocketBufferBytes bounds kernel buffering on both ends of the
	// loopback pair. Without it the loopback stack (macOS autotunes to 4 MiB
	// per direction, Linux similar) absorbs most of a multi-MiB message and
	// the server's write returns long before the client has read it — which
	// would let the pre-fix single-frame path pass the ping test vacuously.
	stallSocketBufferBytes = 64 << 10
	// stallMessageBytes / stallReadChunk / stallReadInterval throttle the
	// client to ~640 KiB/s, so the 6 MiB message takes ~9.5s on the wire: the
	// pong must interleave (fixed path) or the 5s pong budget expires (old
	// path) with a wide margin either way.
	stallMessageBytes = 6 << 20
	stallReadChunk    = 64 << 10
	stallReadInterval = 100 * time.Millisecond
	// stallPingAfterBytes: the client pings once it has read this much of the
	// message, i.e. while the bulk of the write is still ahead.
	stallPingAfterBytes = 256 << 10
	stallPingTimeout    = 6 * time.Second
)

// pingStallHarness is a live nhooyr server+client pair with deliberately
// tiny kernel socket buffers (see stallSocketBufferBytes). The server side
// runs a Read loop that mirrors api.providerReadLoop — that goroutine is
// where nhooyr answers pings, so without it no pong is ever written.
type pingStallHarness struct {
	serverConn *websocket.Conn
	clientConn *websocket.Conn
	// readErr receives the server Read loop's terminal error (once).
	readErr chan error
	// inbound receives every text message the server Read loop delivers.
	inbound chan string
}

type smallSendBufferListener struct {
	net.Listener
}

func (l smallSendBufferListener) Accept() (net.Conn, error) {
	c, err := l.Listener.Accept()
	if err != nil {
		return nil, err
	}
	if tc, ok := c.(*net.TCPConn); ok {
		_ = tc.SetWriteBuffer(stallSocketBufferBytes)
	}
	return c, nil
}

func newPingStallHarness(t *testing.T) *pingStallHarness {
	t.Helper()
	h := &pingStallHarness{
		readErr: make(chan error, 1),
		inbound: make(chan string, 16),
	}
	serverConnCh := make(chan *websocket.Conn, 1)
	srv := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Same accept options as api.handleProviderWS (compression stays at
		// the library default, CompressionDisabled — the production shape).
		conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{InsecureSkipVerify: true})
		if err != nil {
			t.Errorf("accept websocket: %v", err)
			return
		}
		serverConnCh <- conn
		for {
			_, data, err := conn.Read(context.Background())
			if err != nil {
				h.readErr <- err
				// api.providerReadLoop's deferred teardown: the session is
				// gone once Read fails.
				_ = conn.CloseNow()
				return
			}
			h.inbound <- string(data)
		}
	}))
	srv.Listener = smallSendBufferListener{srv.Listener}
	srv.Start()
	t.Cleanup(srv.Close)

	transport := &http.Transport{
		DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
			c, err := (&net.Dialer{}).DialContext(ctx, network, addr)
			if err != nil {
				return nil, err
			}
			if tc, ok := c.(*net.TCPConn); ok {
				_ = tc.SetReadBuffer(stallSocketBufferBytes)
			}
			return c, nil
		},
	}
	dialCtx, cancelDial := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancelDial()
	clientConn, _, err := websocket.Dial(dialCtx, "ws"+strings.TrimPrefix(srv.URL, "http"), &websocket.DialOptions{
		HTTPClient: &http.Client{Transport: transport},
	})
	if err != nil {
		t.Fatalf("dial websocket: %v", err)
	}
	clientConn.SetReadLimit(-1)
	t.Cleanup(func() { _ = clientConn.CloseNow() })
	h.clientConn = clientConn

	select {
	case h.serverConn = <-serverConnCh:
		t.Cleanup(func() { _ = h.serverConn.CloseNow() })
	case <-time.After(5 * time.Second):
		t.Fatal("timed out waiting for server websocket")
	}
	return h
}

// stallPayload is an ASCII (valid UTF-8, incompressible-enough) text message
// of the given size, shaped like a sealed inference_request envelope.
func stallPayload(n int) []byte {
	rng := rand.New(rand.NewSource(7))
	const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
	prefix := `{"type":"inference_request","payload":"`
	suffix := `"}`
	body := make([]byte, n-len(prefix)-len(suffix))
	for i := range body {
		body[i] = alphabet[rng.Intn(len(alphabet))]
	}
	out := make([]byte, 0, n)
	out = append(out, prefix...)
	out = append(out, body...)
	return append(out, suffix...)
}

// slowReadResult is what the throttled client reader observed.
type slowReadResult struct {
	data []byte
	err  error
}

// readMessageSlowly drains one message from the client at stallReadChunk per
// stallReadInterval. bytesRead is updated after every chunk; pingGate is
// closed once stallPingAfterBytes have been read.
func readMessageSlowly(conn *websocket.Conn, bytesRead *atomic.Int64, pingGate chan struct{}) slowReadResult {
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	typ, r, err := conn.Reader(ctx)
	if err != nil {
		return slowReadResult{err: err}
	}
	if typ != websocket.MessageText {
		return slowReadResult{err: fmt.Errorf("message type = %v, want text", typ)}
	}
	var got []byte
	buf := make([]byte, stallReadChunk)
	gateOpen := false
	for {
		n, err := r.Read(buf)
		got = append(got, buf[:n]...)
		total := bytesRead.Add(int64(n))
		if !gateOpen && total >= stallPingAfterBytes {
			gateOpen = true
			close(pingGate)
		}
		if errors.Is(err, io.EOF) {
			return slowReadResult{data: got}
		}
		if err != nil {
			return slowReadResult{data: got, err: err}
		}
		time.Sleep(stallReadInterval)
	}
}
