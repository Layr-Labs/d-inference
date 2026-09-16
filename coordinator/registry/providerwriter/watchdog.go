package providerwriter

import (
	"time"
)

// watchWrites enforces per-frame write deadlines with one goroutine per
// connection instead of a goroutine+timer per frame. writeFrame publishes its
// deadline before the blocking socket write of a whole message and clears it
// after; when a deadline is exceeded the watchdog closes the socket, which
// unblocks the write with an error. Granularity is
// watchdogInterval, acceptable slack on a >=5s timeout floor.
func (w *Writer) watchWrites(stop <-chan struct{}) {
	ticker := time.NewTicker(watchdogInterval)
	defer ticker.Stop()
	for {
		select {
		case <-stop:
			return
		case <-w.stop:
			return
		case <-ticker.C:
			d := w.writeDeadline.Load()
			if d != 0 && time.Now().UnixNano() > d {
				w.writeTimedOut.Store(true)
				if w.conn != nil {
					_ = w.conn.CloseNow()
				}
				return
			}
		}
	}
}
