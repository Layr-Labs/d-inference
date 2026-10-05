package providerwrite

import "nhooyr.io/websocket"

// Factory binds a connection to the writer retained for that exact session.
// The returned worker has one lifecycle owner: provider registration/disconnect.
type Factory interface {
	Open(session string, conn *websocket.Conn) *Writer
}

type SocketFactory struct{}

func (SocketFactory) Open(_ string, conn *websocket.Conn) *Writer { return NewSocket(conn) }
