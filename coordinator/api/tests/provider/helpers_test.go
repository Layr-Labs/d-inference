package provider_test

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"io"
	"log/slog"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api"
	"github.com/eigeninference/d-inference/coordinator/api/tests/internal/testkit"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"nhooyr.io/websocket"
)

func setupTestServer(t testing.TB) (*api.Server, *registry.Registry, store.Store, *httptest.Server) {
	t.Helper()
	f := testkit.New(t, api.ServerConfig{})
	f.Server.SetChallengeInterval(200 * time.Millisecond)
	ts := httptest.NewServer(f.Server.Handler())
	t.Cleanup(ts.Close)
	return f.Server, f.Registry, f.Store, ts
}

func quietLogger() *slog.Logger { return slog.New(slog.NewTextHandler(io.Discard, nil)) }

func providerTokenHash(token string) string {
	hash := sha256.Sum256([]byte(token))
	return hex.EncodeToString(hash[:])
}

func sendComplete(ctx context.Context, conn *websocket.Conn, requestID string, usage protocol.UsageInfo) {
	data, _ := json.Marshal(protocol.InferenceCompleteMessage{Type: protocol.TypeInferenceComplete, RequestID: requestID, Usage: usage})
	_ = conn.Write(ctx, websocket.MessageText, data)
}
