package registry

// Regression tests for fragmented data-lane writes (writeFragmented).
//
// nhooyr's Conn.Write sends a whole message as ONE frame while holding the
// connection's per-frame write lock, and its read goroutine answers peer
// pings inline with a 5s budget to take that same lock. A multi-MiB
// inference frame on a slow provider uplink legitimately takes longer than
// that, so a provider ping (every 10s) landing mid-frame failed the pong and
// nhooyr reported it as a READ error — tearing down the whole provider
// session (2026-08-31 "provider websocket read error" 502 cascade). The
// tests below reproduce that stall on a live loopback pair and prove that
// fragmenting the message lets the pong interleave.

import (
	"bufio"
	"context"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"math/rand"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
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

// TestProviderWriterFragmentedWriteAnswersPingMidMessage is the regression
// test for the 2026-08-31 provider-session teardown: a peer ping that lands
// while a multi-second data write is in flight must be answered (the pong
// interleaves between fragments), the server Read loop must survive, and the
// peer must still receive the message byte-for-byte.
//
// Before writeFragmented this failed: the client's Ping timed out, the server
// Read loop died with "failed to get reader: failed to handle control frame
// opPing: failed to write control frame opPong: failed to acquire lock:
// context deadline exceeded", and the message never completed (see
// TestUnfragmentedConnWriteStallsPeerPing, which pins that failure mode).
func TestProviderWriterFragmentedWriteAnswersPingMidMessage(t *testing.T) {
	if testing.Short() {
		t.Skip("wall-clock-bounded slow-reader test (~10s; asserts a >5s stall)")
	}
	t.Parallel()
	h := newPingStallHarness(t)
	w := newProviderWriter(h.serverConn)
	// The reader is throttled below the 2 MiB/s write-timeout floor on
	// purpose; the watchdog is not what is under test here.
	w.timeoutFor = func(int) time.Duration { return 60 * time.Second }
	p := &Provider{Conn: h.serverConn, writer: w}
	t.Cleanup(p.closeWriterNow)

	payload := stallPayload(stallMessageBytes)

	var bytesRead atomic.Int64
	pingGate := make(chan struct{})
	readDone := make(chan slowReadResult, 1)
	go func() { readDone <- readMessageSlowly(h.clientConn, &bytesRead, pingGate) }()

	writeDone := make(chan error, 1)
	writeStarted := time.Now()
	go func() { writeDone <- p.WriteText(context.Background(), payload) }()

	select {
	case <-pingGate:
	case res := <-readDone:
		t.Fatalf("client read finished before the ping gate: %d bytes, err=%v", len(res.data), res.err)
	case <-time.After(30 * time.Second):
		t.Fatal("timed out waiting for the client to read the ping gate")
	}

	pingCtx, cancelPing := context.WithTimeout(context.Background(), stallPingTimeout)
	defer cancelPing()
	pingErr := h.clientConn.Ping(pingCtx)
	bytesAtPong := bytesRead.Load()
	if pingErr != nil {
		t.Fatalf("Ping during in-flight data write = %v (pong could not interleave)", pingErr)
	}
	// The pong must have interleaved with the message, not trailed it: the
	// write is still in progress and the client has not read all of it.
	select {
	case err := <-writeDone:
		t.Fatalf("WriteText already returned (%v) when the pong arrived; the harness did not keep the write in flight", err)
	default:
	}
	if bytesAtPong >= int64(len(payload)) {
		t.Fatalf("client had read %d of %d bytes when the pong arrived; the pong did not interleave", bytesAtPong, len(payload))
	}

	select {
	case err := <-writeDone:
		if err != nil {
			t.Fatalf("WriteText = %v", err)
		}
	case <-time.After(60 * time.Second):
		t.Fatal("timed out waiting for WriteText")
	}
	writeTook := time.Since(writeStarted)
	if writeTook < 5*time.Second {
		t.Fatalf("WriteText took %v; the throttled reader should have kept it in flight for >5s (nhooyr's pong budget)", writeTook)
	}

	var res slowReadResult
	select {
	case res = <-readDone:
	case <-time.After(60 * time.Second):
		t.Fatal("timed out waiting for the client to finish reading")
	}
	if res.err != nil {
		t.Fatalf("client read = %v after %d bytes", res.err, len(res.data))
	}
	if string(res.data) != string(payload) {
		t.Fatalf("client received %d bytes, want %d, or content differs", len(res.data), len(payload))
	}

	// Positive liveness proof for the server Read loop: it must still deliver
	// the next inbound frame, and must not have exited.
	select {
	case err := <-h.readErr:
		t.Fatalf("server Read loop exited during the fragmented write: %v", err)
	default:
	}
	writeCtx, cancelWrite := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancelWrite()
	if err := h.clientConn.Write(writeCtx, websocket.MessageText, []byte(`{"type":"heartbeat"}`)); err != nil {
		t.Fatalf("client write after message: %v", err)
	}
	select {
	case msg := <-h.inbound:
		if msg != `{"type":"heartbeat"}` {
			t.Fatalf("server read %q after the fragmented write, want heartbeat", msg)
		}
	case err := <-h.readErr:
		t.Fatalf("server Read loop exited after the fragmented write: %v", err)
	case <-time.After(5 * time.Second):
		t.Fatal("server Read loop did not deliver the post-message heartbeat")
	}
	t.Logf("pong arrived after %d/%d bytes; write took %v", bytesAtPong, len(payload), writeTook)
}

// TestUnfragmentedConnWriteStallsPeerPing pins the library behavior that
// motivated writeFragmented, using the pre-fix path (one nhooyr Conn.Write
// for the whole message) on the same harness: the peer's ping cannot be
// answered while the frame is in flight, and nhooyr surfaces that as a READ
// failure containing "failed to handle control frame" — the exact string
// api.readErrorDisconnectReason classifies. It also proves the harness is
// sensitive enough that the fragmented test above cannot pass vacuously.
func TestUnfragmentedConnWriteStallsPeerPing(t *testing.T) {
	if testing.Short() {
		t.Skip("wall-clock-bounded slow-reader test (~6s; asserts a >5s stall)")
	}
	t.Parallel()
	h := newPingStallHarness(t)
	payload := stallPayload(stallMessageBytes)

	var bytesRead atomic.Int64
	pingGate := make(chan struct{})
	readDone := make(chan slowReadResult, 1)
	go func() { readDone <- readMessageSlowly(h.clientConn, &bytesRead, pingGate) }()

	writeDone := make(chan error, 1)
	go func() {
		writeDone <- h.serverConn.Write(context.Background(), websocket.MessageText, payload)
	}()

	select {
	case <-pingGate:
	case res := <-readDone:
		t.Fatalf("client read finished before the ping gate: %d bytes, err=%v", len(res.data), res.err)
	case <-time.After(30 * time.Second):
		t.Fatal("timed out waiting for the client to read the ping gate")
	}

	pingCtx, cancelPing := context.WithTimeout(context.Background(), stallPingTimeout)
	defer cancelPing()
	pingErr := h.clientConn.Ping(pingCtx)
	if pingErr == nil {
		t.Fatal("Ping succeeded during a single-frame Conn.Write; nhooyr no longer holds the write lock for the whole message — the harness is not exercising the stall")
	}

	var readErr error
	select {
	case readErr = <-h.readErr:
	case <-time.After(15 * time.Second):
		t.Fatal("server Read loop did not fail after the unanswered ping")
	}
	// This is the string api.readErrorDisconnectReason keys on, and the
	// lock wait is the mechanism (nhooyr names the opcodes opPing/opPong).
	for _, want := range []string{"failed to handle control frame", "failed to acquire lock"} {
		if !strings.Contains(readErr.Error(), want) {
			t.Fatalf("server Read error = %q, want it to contain %q", readErr, want)
		}
	}
	t.Logf("pre-fix failure mode reproduced: Ping=%v; server Read=%v", pingErr, readErr)

	// The harness tore the socket down on the read failure, so the in-flight
	// write and the client read both fail: this is the provider-session 502
	// cascade.
	select {
	case err := <-writeDone:
		if err == nil {
			t.Fatal("single-frame Write completed after the Read loop died")
		}
	case <-time.After(15 * time.Second):
		t.Fatal("timed out waiting for the stalled Write to fail")
	}
	select {
	case res := <-readDone:
		if res.err == nil {
			t.Fatalf("client read completed (%d bytes) after the server session died", len(res.data))
		}
	case <-time.After(15 * time.Second):
		t.Fatal("timed out waiting for the client read to fail")
	}
}

// rawWSClient speaks just enough RFC 6455 to observe server→client frame
// boundaries: the HTTP upgrade, then unmasked frame headers. It offers no
// extensions, so the server side is exactly the production (flate-disabled)
// framing.
type rawWSClient struct {
	conn net.Conn
	br   *bufio.Reader
}

type rawFrame struct {
	fin     bool
	opcode  byte
	payload []byte
}

const (
	rawOpContinuation = 0x0
	rawOpText         = 0x1
)

func dialRawWS(t *testing.T, serverURL string) *rawWSClient {
	t.Helper()
	u, err := url.Parse(serverURL)
	if err != nil {
		t.Fatalf("parse server url: %v", err)
	}
	conn, err := net.DialTimeout("tcp", u.Host, 5*time.Second)
	if err != nil {
		t.Fatalf("dial raw tcp: %v", err)
	}
	t.Cleanup(func() { _ = conn.Close() })
	_ = conn.SetDeadline(time.Now().Add(30 * time.Second))

	var keyBytes [16]byte
	rand.New(rand.NewSource(time.Now().UnixNano())).Read(keyBytes[:])
	key := base64.StdEncoding.EncodeToString(keyBytes[:])
	if _, err := fmt.Fprintf(conn,
		"GET / HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"+
			"Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n", u.Host, key); err != nil {
		t.Fatalf("write upgrade request: %v", err)
	}
	br := bufio.NewReader(conn)
	resp, err := http.ReadResponse(br, nil)
	if err != nil {
		t.Fatalf("read upgrade response: %v", err)
	}
	if resp.StatusCode != http.StatusSwitchingProtocols {
		t.Fatalf("upgrade status = %d, want 101", resp.StatusCode)
	}
	return &rawWSClient{conn: conn, br: br}
}

func (c *rawWSClient) readFrame() (rawFrame, error) {
	var hdr [2]byte
	if _, err := io.ReadFull(c.br, hdr[:]); err != nil {
		return rawFrame{}, fmt.Errorf("frame header: %w", err)
	}
	f := rawFrame{fin: hdr[0]&0x80 != 0, opcode: hdr[0] & 0x0f}
	if hdr[1]&0x80 != 0 {
		return rawFrame{}, errors.New("server frame is masked")
	}
	n := uint64(hdr[1] & 0x7f)
	switch n {
	case 126:
		var ext [2]byte
		if _, err := io.ReadFull(c.br, ext[:]); err != nil {
			return rawFrame{}, fmt.Errorf("extended length: %w", err)
		}
		n = uint64(binary.BigEndian.Uint16(ext[:]))
	case 127:
		var ext [8]byte
		if _, err := io.ReadFull(c.br, ext[:]); err != nil {
			return rawFrame{}, fmt.Errorf("extended length: %w", err)
		}
		n = binary.BigEndian.Uint64(ext[:])
	}
	f.payload = make([]byte, n)
	if _, err := io.ReadFull(c.br, f.payload); err != nil {
		return rawFrame{}, fmt.Errorf("frame payload (%d bytes): %w", n, err)
	}
	return f, nil
}

// readMessageFrames reads frames until a FIN frame and returns them all.
func (c *rawWSClient) readMessageFrames() ([]rawFrame, error) {
	var frames []rawFrame
	for {
		f, err := c.readFrame()
		if err != nil {
			return frames, err
		}
		frames = append(frames, f)
		if f.fin {
			return frames, nil
		}
	}
}

// TestProviderWriterFragmentBoundaries checks the wire framing of
// writeFragmented across the fragment threshold: messages up to one fragment
// stay a single FIN text frame; larger ones become ceil(n/fragment) non-FIN
// frames (text, then continuation) of at most fragment bytes, terminated by
// nhooyr's zero-length FIN continuation — and always reassemble exactly.
func TestProviderWriterFragmentBoundaries(t *testing.T) {
	const f = providerWriteFragmentBytes
	serverConnCh := make(chan *websocket.Conn, 1)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{InsecureSkipVerify: true})
		if err != nil {
			t.Errorf("accept websocket: %v", err)
			return
		}
		serverConnCh <- conn
		// Keep the handler (and the hijacked socket) alive; nothing is read.
		<-r.Context().Done()
	}))
	t.Cleanup(srv.Close)
	client := dialRawWS(t, srv.URL)
	var serverConn *websocket.Conn
	select {
	case serverConn = <-serverConnCh:
	case <-time.After(5 * time.Second):
		t.Fatal("timed out waiting for server websocket")
	}
	w := newProviderWriter(serverConn)
	t.Cleanup(w.closeNow)

	for _, size := range []int{0, 1, f - 1, f, f + 1, 3*f + 17} {
		t.Run(fmt.Sprintf("size=%d", size), func(t *testing.T) {
			data := make([]byte, size)
			rng := rand.New(rand.NewSource(int64(size)))
			for i := range data {
				data[i] = byte('a' + rng.Intn(26))
			}
			if err := w.write(context.Background(), data); err != nil {
				t.Fatalf("write %d bytes: %v", size, err)
			}
			frames, err := client.readMessageFrames()
			if err != nil {
				t.Fatalf("read frames for %d bytes: %v (got %d frames)", size, err, len(frames))
			}

			var wantFrames int
			if size <= f {
				wantFrames = 1
			} else {
				wantFrames = (size+f-1)/f + 1
			}
			if len(frames) != wantFrames {
				t.Fatalf("frame count = %d, want %d", len(frames), wantFrames)
			}
			var joined []byte
			for i, fr := range frames {
				joined = append(joined, fr.payload...)
				last := i == len(frames)-1
				wantOpcode := byte(rawOpContinuation)
				if i == 0 {
					wantOpcode = rawOpText
				}
				if fr.opcode != wantOpcode {
					t.Fatalf("frame[%d] opcode = %#x, want %#x", i, fr.opcode, wantOpcode)
				}
				if fr.fin != last {
					t.Fatalf("frame[%d] fin = %v, want %v", i, fr.fin, last)
				}
				switch {
				case wantFrames == 1:
					if len(fr.payload) != size {
						t.Fatalf("single frame payload = %d, want %d", len(fr.payload), size)
					}
				case last:
					if len(fr.payload) != 0 {
						t.Fatalf("FIN continuation payload = %d, want 0", len(fr.payload))
					}
				case i == wantFrames-2:
					wantLast := size - (wantFrames-2)*f
					if len(fr.payload) != wantLast {
						t.Fatalf("last data fragment payload = %d, want %d", len(fr.payload), wantLast)
					}
				default:
					if len(fr.payload) != f {
						t.Fatalf("frame[%d] payload = %d, want %d", i, len(fr.payload), f)
					}
				}
			}
			if string(joined) != string(data) {
				t.Fatalf("reassembled %d bytes differ from the %d-byte message", len(joined), size)
			}
		})
	}
}
