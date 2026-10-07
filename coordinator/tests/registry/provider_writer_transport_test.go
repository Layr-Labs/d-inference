package registry_test

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
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/writedeadline"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/writertransport"
	"nhooyr.io/websocket"
)

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
	t.Parallel()
	h := newPingStallHarness(t)
	watchdog := &writedeadline.Watchdog{}
	stop := make(chan struct{})
	defer close(stop)
	go watchdog.Watch(h.serverConn, stop, nil)
	// The reader is deliberately slower than the production floor. Keep the
	// same 60-second transport deadline while exercising the framing itself.

	payload := stallPayload(stallMessageBytes)

	var bytesRead atomic.Int64
	pingGate := make(chan struct{})
	readDone := make(chan slowReadResult, 1)
	go func() { readDone <- readMessageSlowly(h.clientConn, &bytesRead, pingGate) }()

	writeDone := make(chan error, 1)
	writeStarted := time.Now()
	go func() { writeDone <- writertransport.Write(h.serverConn, payload, watchdog, 60*time.Second) }()

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
	const f = 256 << 10 // the production fragment-size contract
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
	watchdog := &writedeadline.Watchdog{}
	stop := make(chan struct{})
	defer close(stop)
	go watchdog.Watch(serverConn, stop, nil)
	t.Cleanup(func() { _ = serverConn.CloseNow() })

	for _, size := range []int{0, 1, f - 1, f, f + 1, 3*f + 17} {
		t.Run(fmt.Sprintf("size=%d", size), func(t *testing.T) {
			data := make([]byte, size)
			rng := rand.New(rand.NewSource(int64(size)))
			for i := range data {
				data[i] = byte('a' + rng.Intn(26))
			}
			if err := writertransport.Write(serverConn, data, watchdog, writertransport.Timeout(len(data))); err != nil {
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
