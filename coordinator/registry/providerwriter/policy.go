package providerwriter

import (
	"errors"
	"time"
)

const (
	dataQueueSize = 128
	// controlQueueSize bounds the priority lane. Its frames are tiny
	// (cancel / challenge / status, ~100 B) so the cost of depth is nil, while a
	// full lane silently drops a cancel — the one loss path on the coordinator
	// side of cancel delivery (inference.cancel_send_failed{reason:queue_full}).
	controlQueueSize    = 256
	minWriteTimeout     = 5 * time.Second
	maxWriteTimeout     = 30 * time.Second
	writeBytesPerSecond = 2 << 20 // 2 MiB/s (~16 Mbps) floor.
	// fragmentBytes is the WebSocket fragment size for data-lane
	// messages larger than one fragment. nhooyr answers peer pings on its READ
	// goroutine, under a 5s budget, and that pong needs the per-frame write
	// lock — so a message must never be one multi-second frame (see
	// writeFrame). 256 KiB keeps ~100 frames per 20 MiB vision request while
	// bounding the pong's wait to one fragment's wire time.
	fragmentBytes       = 256 << 10
	ControlWriteTimeout = 5 * time.Second
	watchdogInterval    = 250 * time.Millisecond
	drainErrorString    = "provider websocket writer stopped"
)

var errStopped = errors.New(drainErrorString)

var errQueueFull = errors.New("provider websocket writer queue full")

var errWriteTimeout = errors.New("provider websocket write timeout")

// Exported forms of the writer's sentinel errors so callers can classify a
// best-effort control-frame failure (cancel delivery metrics) with errors.Is.
var (
	ErrQueueFull = errQueueFull
	ErrStopped   = errStopped
)

func writeTimeout(frameBytes int) time.Duration {
	if frameBytes <= 0 {
		return minWriteTimeout
	}
	d := time.Duration(frameBytes) * time.Second / writeBytesPerSecond
	if d < minWriteTimeout {
		return minWriteTimeout
	}
	if d > maxWriteTimeout {
		return maxWriteTimeout
	}
	return d
}
