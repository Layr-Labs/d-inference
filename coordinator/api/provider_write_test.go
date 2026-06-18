package api

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/registry"
	"nhooyr.io/websocket"
)

func TestProviderDispatchWriteTimeoutScalesWithFrameSize(t *testing.T) {
	if got := providerDispatchWriteTimeout(1); got != providerDispatchWriteMinTimeout {
		t.Fatalf("tiny frame timeout = %v, want min %v", got, providerDispatchWriteMinTimeout)
	}
	large := providerDispatchWriteBytesPerSecond * 10
	if got := providerDispatchWriteTimeout(large); got != 10*time.Second {
		t.Fatalf("large frame timeout = %v, want 10s", got)
	}
	tooLarge := providerDispatchWriteBytesPerSecond * 100
	if got := providerDispatchWriteTimeout(tooLarge); got != providerDispatchWriteMaxTimeout {
		t.Fatalf("huge frame timeout = %v, want max %v", got, providerDispatchWriteMaxTimeout)
	}
}

func TestWriteProviderInferenceRequestIgnoresConsumerCancel(t *testing.T) {
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

	consumerCtx, cancelConsumer := context.WithCancel(context.Background())
	cancelConsumer()

	provider := &registry.Provider{Conn: serverConn}
	if err := writeProviderInferenceRequest(consumerCtx, provider, []byte(`{"type":"inference_request"}`)); err != nil {
		t.Fatalf("writeProviderInferenceRequest returned error with canceled consumer context: %v", err)
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
