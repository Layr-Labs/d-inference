package api

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"nhooyr.io/websocket"
)

func TestCacheEligibilityHeartbeatLifecycleThroughProviderWebSocket(t *testing.T) {
	logger := slog.New(slog.DiscardHandler)
	reg := registry.New(logger)
	srv := NewServer(reg, store.NewMemory(store.Config{}), ServerConfig{}, logger)
	httpServer := httptest.NewServer(srv.Handler())
	defer httpServer.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	conn, _, err := websocket.Dial(
		ctx,
		"ws"+strings.TrimPrefix(httpServer.URL, "http")+"/ws/provider",
		nil,
	)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close(websocket.StatusNormalClosure, "")

	initialStatuses := []protocol.PrefixCacheModelStatus{{
		ModelID: "model", Backend: "contiguous", ReplayStrategy: "none",
		State: "disabled", Reason: "weight_hash_unavailable",
	}}
	initialOutcomes := []protocol.PrefixCacheDonationOutcomeCount{{
		Outcome: "donated", Count: 2,
	}}
	writeProviderJSON(t, ctx, conn, protocol.RegisterMessage{
		Type:                        protocol.TypeRegister,
		Models:                      []protocol.ModelInfo{{ID: "model"}},
		Backend:                     "mlx-swift",
		PrefixCacheProtocol:         1,
		PrefixCacheStatuses:         &initialStatuses,
		PrefixCacheDonationOutcomes: &initialOutcomes,
	})
	waitCacheCondition(t, func() bool {
		status := reg.PrefixCacheProtocolStatus()
		return status.ReportedLoadedModels == 1 &&
			status.ByReason["weight_hash_unavailable"] == 1
	})

	replacement := []protocol.PrefixCacheModelStatus{{
		ModelID: "model", Backend: "contiguous", ReplayStrategy: "direct",
		State: "pending", Reason: "scan_pending",
	}}
	fiveOutcomes := []protocol.PrefixCacheDonationOutcomeCount{{
		Outcome: "donated", Count: 5,
	}}
	writeProviderJSON(t, ctx, conn, protocol.HeartbeatMessage{
		Type: protocol.TypeHeartbeat, Status: "idle",
		Stats:                       protocol.HeartbeatStats{},
		PrefixCacheStatuses:         &replacement,
		PrefixCacheDonationOutcomes: &fiveOutcomes,
	})
	waitCacheCondition(t, func() bool {
		status := reg.PrefixCacheProtocolStatus()
		return status.ByReason["scan_pending"] == 1 &&
			reg.CacheRoutingLifecycleStatus().DonationOutcomes["donated"] == 3
	})

	empty := []protocol.PrefixCacheModelStatus{}
	writeProviderJSON(t, ctx, conn, protocol.HeartbeatMessage{
		Type: protocol.TypeHeartbeat, Status: "idle",
		Stats:                       protocol.HeartbeatStats{},
		PrefixCacheStatuses:         &empty,
		PrefixCacheDonationOutcomes: &fiveOutcomes,
	})
	waitCacheCondition(t, func() bool {
		return reg.PrefixCacheProtocolStatus().ReportedLoadedModels == 0
	})

	// An old-provider-style omission does not recreate or fabricate status.
	writeProviderJSON(t, ctx, conn, protocol.HeartbeatMessage{
		Type: protocol.TypeHeartbeat, Status: "idle", Stats: protocol.HeartbeatStats{},
	})
	time.Sleep(25 * time.Millisecond)
	if got := reg.PrefixCacheProtocolStatus().ReportedLoadedModels; got != 0 {
		t.Fatalf("omitted snapshot changed authoritative clear: %d", got)
	}

	if err := conn.Close(websocket.StatusNormalClosure, "done"); err != nil {
		t.Fatal(err)
	}
	waitCacheCondition(t, func() bool { return reg.ProviderCount() == 0 })
	if got := reg.PrefixCacheProtocolStatus().LoadedModels; got != 0 {
		t.Fatalf("disconnect retained loaded status: %d", got)
	}
}

func writeProviderJSON(t *testing.T, ctx context.Context, conn *websocket.Conn, value any) {
	t.Helper()
	data, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	if err := conn.Write(ctx, websocket.MessageText, data); err != nil {
		t.Fatal(err)
	}
}

func waitCacheCondition(t *testing.T, condition func() bool) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if condition() {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("timed out waiting for cache telemetry state")
}
