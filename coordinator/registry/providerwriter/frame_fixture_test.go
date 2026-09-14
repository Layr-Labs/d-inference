package providerwriter

import (
	"bufio"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"math/rand"
	"net"
	"net/http"
	"net/url"
	"testing"
	"time"
)

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
