package api

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"nhooyr.io/websocket"
)

func TestNativePairWorkerActualReadLoopRefusesAllFourKindsWithoutGrant(t *testing.T) {
	for _, kind := range []string{protocol.TypeNativePairWorkerReady, protocol.TypeNativePairWorkerCommand,
		protocol.TypeNativePairWorkerEvent, protocol.TypeNativePairWorkerAttach} {
		t.Run(kind, func(t *testing.T) {
			s, _ := testServer(t)
			defer s.Close()
			server := httptest.NewServer(http.HandlerFunc(s.handleProviderWS))
			defer server.Close()
			ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
			defer cancel()
			conn, _, e := websocket.Dial(ctx, "ws"+strings.TrimPrefix(server.URL, "http"), nil)
			if e != nil {
				t.Fatal(e)
			}
			defer conn.CloseNow()
			b := []byte(`{"type":"` + kind + `","version":1,"member_nonce":"` + strings.Repeat("1", 64) + `","epoch":"` + strings.Repeat("2", 32) + `","generation":1,"sequence":1,"payload":"","signature":"MAYCAQECAQE="}`)
			var decoded protocol.ProviderMessage
			if e = protocol.DecodeProviderMessage(b, &decoded); e != nil {
				t.Fatal(e)
			}
			if _, ok := decoded.Payload.(*protocol.NativePairMessage); !ok {
				t.Fatal("worker discriminator bypassed closed native decoder")
			}
			if e = conn.Write(ctx, websocket.MessageText, b); e != nil {
				t.Fatal(e)
			}
			_, _, e = conn.Read(ctx)
			if websocket.CloseStatus(e) != websocket.StatusPolicyViolation {
				t.Fatal("worker record without original grant was not refused", e)
			}
		})
	}
}
