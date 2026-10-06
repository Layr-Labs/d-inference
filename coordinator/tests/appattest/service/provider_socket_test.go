package service_test

import (
	"context"
	"net"
	"net/http"
	"sync"
	"testing"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"nhooyr.io/websocket"
)

// pipeListener serves exactly one in-memory connection. Nothing touches the
// network, so inside a synctest bubble fake time can pass the exchange's
// jitter and 90-second response timers instantly.
type pipeListener struct {
	conns chan net.Conn
	once  sync.Once
	done  chan struct{}
}

func (l *pipeListener) Accept() (net.Conn, error) {
	select {
	case c := <-l.conns:
		return c, nil
	case <-l.done:
		return nil, net.ErrClosed
	}
}

func (l *pipeListener) Close() error   { l.once.Do(func() { close(l.done) }); return nil }
func (l *pipeListener) Addr() net.Addr { return pipeAddr{} }

type pipeAddr struct{}

func (pipeAddr) Network() string { return "pipe" }
func (pipeAddr) String() string  { return "pipe" }

// pipeWebSocket returns a server-side conn for the provider writer and the
// client conn that reads what the coordinator sent.
func pipeWebSocket(t *testing.T) (server, client *websocket.Conn, closeAll func()) {
	t.Helper()
	serverSide, clientSide := net.Pipe()
	ln := &pipeListener{conns: make(chan net.Conn, 1), done: make(chan struct{})}
	ln.conns <- serverSide
	accepted := make(chan *websocket.Conn, 1)
	srv := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		c, err := websocket.Accept(w, r, nil)
		if err != nil {
			t.Errorf("accept: %v", err)
			return
		}
		accepted <- c
	})}
	go func() { _ = srv.Serve(ln) }()
	transport := &http.Transport{DialContext: func(context.Context, string, string) (net.Conn, error) { return clientSide, nil }}
	client, _, err := websocket.Dial(context.Background(), "ws://pipe/", &websocket.DialOptions{HTTPClient: &http.Client{Transport: transport}})
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	server = <-accepted
	return server, client, func() {
		_ = client.CloseNow()
		_ = server.CloseNow()
		_ = srv.Close()
		transport.CloseIdleConnections()
	}
}

// connectedShadowProvider registers a provider whose writer sends frames over
// an in-memory websocket. The returned client conn reads what the coordinator
// sent.
func connectedShadowProvider(t *testing.T, endpoint string) (*registry.Provider, *websocket.Conn) {
	t.Helper()
	server, client, closeAll := pipeWebSocket(t)
	t.Cleanup(closeAll)
	r := registry.New(discardLogger())
	p := r.Register("connected", server, &protocol.RegisterMessage{PublicKey: endpoint})
	t.Cleanup(func() { r.Disconnect(p.ID) })
	return p, client
}
