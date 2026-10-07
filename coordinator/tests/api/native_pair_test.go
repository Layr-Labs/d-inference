package api_test

// External coverage of the native-pair coordinator API boundary: default-off
// behavior and unauthenticated-frame refusal through the composed server.

import (
	"context"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/testkit"
	"nhooyr.io/websocket"
)

func TestNativePairAPIDefaultDisabledAndUnregisteredFrameRefused(t *testing.T) {
	f := testkit.New(t, api.ServerConfig{})
	if _, err := f.Server.BeginNativePair([2]*registry.Provider{}, "claimed-hash", time.Minute); err == nil {
		t.Fatal("unconfigured selector approved")
	}
	server := httptest.NewServer(f.Server.Handler())
	defer server.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	conn, _, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(server.URL, "http")+"/ws/provider", nil)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.CloseNow()
	// A syntactically valid public message does not imply registration, native
	// approval or an active handle. It enters the actual provider read loop.
	b := []byte(`{"type":"native_pair_hello","version":1,"member_nonce":"` + strings.Repeat("1", 64) +
		`","epoch":"` + strings.Repeat("2", 32) + `","generation":1,"sequence":1,"payload":"","signature":"MAYCAQECAQE="}`)
	if err = conn.Write(ctx, websocket.MessageText, b); err != nil {
		t.Fatal(err)
	}
	_, _, err = conn.Read(ctx)
	if websocket.CloseStatus(err) != websocket.StatusPolicyViolation {
		t.Fatalf("want policy refusal, got %v", err)
	}
}
