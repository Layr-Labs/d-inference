package api

import (
	"context"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"nhooyr.io/websocket"
)

func TestWriteProviderInferenceRequestUsesProviderQueue(t *testing.T) {
	serverConnCh := make(chan *websocket.Conn, 1)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, err := websocket.Accept(w, r, nil)
		if err != nil {
			t.Errorf("accept websocket: %v", err)
			return
		}
		serverConnCh <- conn
	}))
	defer server.Close()

	dialCtx, cancelDial := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancelDial()
	clientConn, _, err := websocket.Dial(dialCtx, "ws"+strings.TrimPrefix(server.URL, "http"), nil)
	if err != nil {
		t.Fatalf("dial websocket: %v", err)
	}
	defer clientConn.Close(websocket.StatusNormalClosure, "done")

	var serverConn *websocket.Conn
	select {
	case serverConn = <-serverConnCh:
	case <-time.After(5 * time.Second):
		t.Fatal("timed out waiting for server websocket")
	}
	defer serverConn.Close(websocket.StatusNormalClosure, "done")

	reg := registry.New(slog.New(slog.NewTextHandler(io.Discard, nil)))
	provider := reg.Register("provider-write-test", serverConn, &protocol.RegisterMessage{})
	defer reg.Disconnect(provider.ID)
	if err := writeProviderInferenceRequest(context.Background(), provider, []byte(`{"type":"inference_request"}`)); err != nil {
		t.Fatalf("writeProviderInferenceRequest returned error: %v", err)
	}

	readCtx, cancelRead := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancelRead()
	_, data, err := clientConn.Read(readCtx)
	if err != nil {
		t.Fatalf("client read: %v", err)
	}
	if string(data) != `{"type":"inference_request"}` {
		t.Fatalf("data = %s", data)
	}
}
