// Package writertransport writes whole provider messages with bounded fragments.
package writertransport

import (
	"context"
	"errors"
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/writedeadline"
	"nhooyr.io/websocket"
)

const (
	fragmentBytes  = 256 << 10
	minTimeout     = 5 * time.Second
	maxTimeout     = 30 * time.Second
	bytesPerSecond = 2 << 20 // 2 MiB/s (~16 Mbps) floor.
)

var ErrTimeout = errors.New("provider websocket write timeout")

// Write puts one whole text message on the wire and returns only once
// its last frame has been handed to the socket.
//
// Messages larger than fragmentBytes are sent as a fragmented
// WebSocket message (RFC 6455 §5.4) rather than one frame. nhooyr's
// Conn.Write holds the connection's per-frame write lock for the entire
// message, and its read goroutine answers the peer's pings inline — with a
// 5s budget to take that same lock. A single 20 MiB vision frame legitimately
// takes 10–30s at the write-timeout floor, so a provider ping (every 10s)
// landing mid-frame failed the pong, which nhooyr reports as a READ error
// ("failed to handle control frame opPing: ... failed to acquire lock"),
// tearing down the whole provider session and 502-ing every request on it.
// With msgWriter.Write the lock is held per fragment, so the pong interleaves
// between continuation frames; the receiver reassembles into one message.
func Write(conn *websocket.Conn, data []byte, watchdog *writedeadline.Watchdog, timeout time.Duration) error {
	// Do not pass a cancelable/expiring context to nhooyr's Write/Writer:
	// context expiration is treated as a connection-level failure by the
	// library. The writer owns timeout/backpressure externally (watchWrites,
	// one deadline for the whole message) and closes unhealthy sockets
	// explicitly with CloseNow.
	watchdog.Deadline.Store(time.Now().Add(timeout).UnixNano())
	err := writeFragmented(conn, data)
	watchdog.Deadline.Store(0)
	if err != nil && watchdog.TimedOut.Load() {
		return ErrTimeout
	}
	return err
}

// writeFragmented sends data as one text message: a single frame when it
// fits in fragmentBytes, otherwise ceil(n/fragment) non-FIN
// frames of at most fragment bytes followed by nhooyr's zero-length FIN
// continuation. A mid-message write error is returned as-is without
// attempting the FIN frame; the caller closes the socket on any error, which
// is also what makes nhooyr's unreleased message-writer lock irrelevant.
func writeFragmented(conn *websocket.Conn, data []byte) error {
	if len(data) <= fragmentBytes {
		return conn.Write(context.Background(), websocket.MessageText, data)
	}
	mw, err := conn.Writer(context.Background(), websocket.MessageText)
	if err != nil {
		return err
	}
	for off := 0; off < len(data); off += fragmentBytes {
		end := min(off+fragmentBytes, len(data))
		if _, err := mw.Write(data[off:end]); err != nil {
			return err
		}
	}
	return mw.Close()
}

// Timeout scales the whole-message budget between the transport's fixed bounds.
func Timeout(frameBytes int) time.Duration {
	if frameBytes <= 0 {
		return minTimeout
	}
	d := time.Duration(frameBytes) * time.Second / bytesPerSecond
	if d < minTimeout {
		return minTimeout
	}
	if d > maxTimeout {
		return maxTimeout
	}
	return d
}
