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
	"github.com/eigeninference/d-inference/coordinator/store"
	"nhooyr.io/websocket"
)

// TestLinkMetricsEmitterPublishesPerConnectionDeltas registers a provider on a
// real WebSocket, moves a few frames in each direction, and checks that the
// gauge-loop emitter publishes counts for exactly the increments since the
// previous tick (not the monotonic totals).
func TestLinkMetricsEmitterPublishesPerConnectionDeltas(t *testing.T) {
	collector := newUDPCollector(t)
	defer collector.Close()

	serverConn, clientConn := testWebSocketPairAPI(t)
	go func() {
		for {
			if _, _, err := clientConn.Read(context.Background()); err != nil {
				return
			}
		}
	}()

	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	reg := registry.New(logger)
	srv := NewServer(reg, store.NewMemory(store.Config{AdminKey: "test-key"}), ServerConfig{}, logger)
	ddClient := newTestDD(t, collector)
	defer ddClient.Close()
	srv.SetDatadog(ddClient)

	provider := reg.Register("link-metrics-provider", serverConn, &protocol.RegisterMessage{})
	defer reg.Disconnect(provider.ID)

	if err := provider.WriteText(context.Background(), []byte(`{"type":"inference_request"}`)); err != nil {
		t.Fatal(err)
	}
	if err := provider.WriteTextControl(context.Background(), []byte(`{"type":"cancel"}`)); err != nil {
		t.Fatal(err)
	}
	provider.RecordInboundFrame(protocol.TypeInferenceResponseChunk, 512)
	provider.RecordInboundFrame(protocol.TypeInferenceResponseChunk, 512)
	provider.RecordInboundFrame(protocol.TypeHeartbeat, 2048)

	emitter := newLinkMetricsEmitter()
	emitter.emit(srv)
	_ = ddClient.Statsd.Flush()
	packets := collector.drain()

	want := map[string]string{
		"provider.ws.connections":   "1|g",
		"provider.ws.frames_in:2|c": "kind:chunk",
		"provider.ws.bytes_in:1024": "kind:chunk",
		"provider.ws.frames_in:1|c": "kind:heartbeat",
		"provider.ws.bytes_in:2048": "kind:heartbeat",
		"provider.ws.frames_out:1":  "lane:data",
		"provider.ws.bytes_out:28":  "lane:data",
		"provider.ws.frames_out:1|": "lane:control",
	}
	for metric, tag := range want {
		if !hasMetricWithTag(packets, metric, tag) {
			t.Errorf("missing %s with %s; packets: %v", metric, tag, packets)
		}
	}
	if hasMetric(packets, "provider.ws.queue_full:1") || hasMetric(packets, "provider.ws.write_timeouts:1") {
		t.Errorf("unexpected error counters: %v", packets)
	}

	// Second tick with no new traffic: counts are zero deltas, the
	// connection gauge is still 1.
	emitter.emit(srv)
	_ = ddClient.Statsd.Flush()
	packets = collector.drain()
	if !hasMetricWithTag(packets, "provider.ws.frames_in:0|c", "kind:chunk") {
		t.Errorf("second tick should emit a zero chunk delta; packets: %v", packets)
	}
	if !hasMetric(packets, "provider.ws.connections:1|g") {
		t.Errorf("second tick should still gauge one connection; packets: %v", packets)
	}

	// A disconnected provider drops out of the gauge and contributes no
	// negative delta.
	reg.Disconnect(provider.ID)
	emitter.emit(srv)
	_ = ddClient.Statsd.Flush()
	packets = collector.drain()
	if !hasMetric(packets, "provider.ws.connections:0|g") {
		t.Errorf("after disconnect connections gauge should be 0; packets: %v", packets)
	}
	for _, p := range packets {
		if strings.Contains(p, "provider.ws.") && strings.Contains(p, ":-") {
			t.Errorf("negative delta emitted: %s", p)
		}
	}
}

func hasMetricWithTag(packets []string, metricPrefix, tag string) bool {
	for _, p := range packets {
		if strings.Contains(p, metricPrefix) && strings.Contains(p, tag) {
			return true
		}
	}
	return false
}

// newWSEchoAcceptServer is an httptest server that accepts one provider-style
// WebSocket per request and hands the server side to the caller.
func newWSEchoAcceptServer(t *testing.T, serverConnCh chan *websocket.Conn) *httptest.Server {
	t.Helper()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, err := websocket.Accept(w, r, nil)
		if err != nil {
			t.Errorf("accept websocket: %v", err)
			return
		}
		serverConnCh <- conn
	}))
	t.Cleanup(server.Close)
	return server
}

// testWebSocketPairAPI is the api-package twin of the registry test helper: a
// real server/client WebSocket pair over loopback.
func testWebSocketPairAPI(t *testing.T) (*websocket.Conn, *websocket.Conn) {
	t.Helper()
	serverConnCh := make(chan *websocket.Conn, 1)
	server := newWSEchoAcceptServer(t, serverConnCh)
	dialCtx, cancelDial := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancelDial()
	clientConn, _, err := websocket.Dial(dialCtx, "ws"+strings.TrimPrefix(server.URL, "http"), nil)
	if err != nil {
		t.Fatalf("dial websocket: %v", err)
	}
	clientConn.SetReadLimit(64 << 20)
	t.Cleanup(func() { _ = clientConn.Close(websocket.StatusNormalClosure, "done") })
	select {
	case serverConn := <-serverConnCh:
		t.Cleanup(func() { _ = serverConn.Close(websocket.StatusNormalClosure, "done") })
		return serverConn, clientConn
	case <-time.After(5 * time.Second):
		t.Fatal("timed out waiting for server websocket")
	}
	return nil, nil
}
