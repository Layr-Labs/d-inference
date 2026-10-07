package providerwrite

import (
	"time"

	"github.com/eigeninference/d-inference/coordinator/internal/registry/writedeadline"
	"github.com/eigeninference/d-inference/coordinator/internal/registry/writertransport"
	"nhooyr.io/websocket"
)

// Transport owns the connection and its whole-message deadline. Caller request
// cancellation is deliberately not passed to Write: a partial frame requires
// closing the connection rather than canceling only one WebSocket operation.
type Transport interface {
	Write([]byte) error
	Close()
	Watch(stop, writerStop <-chan struct{})
}

type SocketTransport struct {
	conn     *websocket.Conn
	watchdog writedeadline.Watchdog
	timeout  func(int) time.Duration
}

func NewSocketTransport(conn *websocket.Conn, timeout func(int) time.Duration) *SocketTransport {
	if timeout == nil {
		timeout = writertransport.Timeout
	}
	return &SocketTransport{conn: conn, timeout: timeout}
}

func (s *SocketTransport) Write(data []byte) error {
	return writertransport.Write(s.conn, data, &s.watchdog, s.timeout(len(data)))
}

func (s *SocketTransport) Close() { _ = s.conn.CloseNow() }

func (s *SocketTransport) Watch(stop, writerStop <-chan struct{}) {
	s.watchdog.Watch(s.conn, stop, writerStop)
}

// TimedOut distinguishes the watchdog's connection close from a peer failure.
func (s *SocketTransport) TimedOut() bool { return s.watchdog.TimedOut.Load() }
