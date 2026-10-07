// Package writedeadline enforces the deadline published by a connection's writer.
package writedeadline

import (
	"sync/atomic"
	"time"

	"nhooyr.io/websocket"
)

const interval = 250 * time.Millisecond

// Watchdog is shared with the transport: the writer publishes and clears the
// whole-message deadline, and the watcher records why it closed the connection.
type Watchdog struct {
	Deadline atomic.Int64
	TimedOut atomic.Bool
}

// Watch enforces per-frame write deadlines with one goroutine per
// connection instead of a goroutine+timer per frame. The transport publishes its
// deadline before the blocking socket write of a whole message and clears it
// after; when a deadline is exceeded the watchdog closes the socket, which
// unblocks the write with an error. Granularity is
// interval, acceptable slack on a >=5s timeout floor.
func (w *Watchdog) Watch(conn *websocket.Conn, stop, writerStop <-chan struct{}) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-stop:
			return
		case <-writerStop:
			return
		case <-ticker.C:
			d := w.Deadline.Load()
			if d != 0 && time.Now().UnixNano() > d {
				w.TimedOut.Store(true)
				if conn != nil {
					_ = conn.CloseNow()
				}
				return
			}
		}
	}
}
