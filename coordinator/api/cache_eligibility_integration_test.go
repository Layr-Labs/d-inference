package api

import (
	"context"
	"encoding/json"
	"log/slog"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"nhooyr.io/websocket"
)

func TestCacheEligibilityHeartbeatLifecycleThroughProviderWebSocket(t *testing.T) {
	logger := slog.New(slog.DiscardHandler)
	reg := registry.New(logger)
	reg.SetModelCatalog([]registry.CatalogEntry{{ID: "public-model"}})
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

	initialStatuses := []protocol.PrefixCacheModelStatus{
		{
			ModelID: "model", Backend: "contiguous", ReplayStrategy: "none",
			State: "disabled", Reason: "weight_hash_unavailable",
		},
		{
			ModelID: "future-model", Backend: "future_backend", ReplayStrategy: "future_strategy",
			State: "warming", Reason: "future_reason",
		},
	}
	initialOutcomes := []protocol.PrefixCacheDonationOutcomeCount{
		{Outcome: "donated", Count: 2},
		{Outcome: "future_outcome", Count: 100},
	}
	writeProviderJSON(t, ctx, conn, protocol.RegisterMessage{
		Type: protocol.TypeRegister,
		Models: []protocol.ModelInfo{
			{ID: "model"},
			{ID: "future-model"},
		},
		Backend:                     "mlx-swift",
		PrefixCacheProtocol:         1,
		PrefixCacheStatuses:         &initialStatuses,
		PrefixCacheDonationOutcomes: &initialOutcomes,
	})
	waitFor(t, 2*time.Second, "cache telemetry state", func() bool {
		status := reg.PrefixCacheProtocolStatus()
		return reg.ProviderCount() == 1 &&
			status.ReportedLoadedModels == 1 &&
			status.ByReason["weight_hash_unavailable"] == 1
	})

	replacement := []protocol.PrefixCacheModelStatus{{
		ModelID: "model", Backend: "contiguous", ReplayStrategy: "direct",
		State: "pending", Reason: "scan_pending",
	}}
	fiveOutcomes := []protocol.PrefixCacheDonationOutcomeCount{
		{Outcome: "donated", Count: 5},
		{Outcome: "future_outcome", Count: 101},
	}
	writeProviderJSON(t, ctx, conn, protocol.HeartbeatMessage{
		Type: protocol.TypeHeartbeat, Status: "idle",
		Stats:                       protocol.HeartbeatStats{},
		PrefixCacheStatuses:         &replacement,
		PrefixCacheDonationOutcomes: &fiveOutcomes,
	})
	waitFor(t, 2*time.Second, "cache telemetry state", func() bool {
		status := reg.PrefixCacheProtocolStatus()
		return status.ByReason["scan_pending"] == 1 &&
			reg.CacheRoutingLifecycleStatus().DonationOutcomes["donated"] == 3
	})

	oversizedStatuses := make([]protocol.PrefixCacheModelStatus, 17)
	duplicateOutcomes := []protocol.PrefixCacheDonationOutcomeCount{
		{Outcome: "donated", Count: 6},
		{Outcome: "donated", Count: 7},
	}
	writeProviderJSON(t, ctx, conn, protocol.HeartbeatMessage{
		Type: protocol.TypeHeartbeat, Status: "idle",
		Stats:                       protocol.HeartbeatStats{},
		PrefixCacheStatuses:         &oversizedStatuses,
		PrefixCacheDonationOutcomes: &duplicateOutcomes,
	})
	waitFor(t, 2*time.Second, "cache telemetry state", func() bool {
		return reg.ProviderCount() == 1 &&
			reg.PrefixCacheProtocolStatus().ReportedLoadedModels == 0 &&
			reg.CacheRoutingLifecycleStatus().DonationOutcomes["donated"] == 3
	})

	sixOutcomes := []protocol.PrefixCacheDonationOutcomeCount{
		{Outcome: "donated", Count: 6},
	}
	writeProviderJSON(t, ctx, conn, protocol.HeartbeatMessage{
		Type: protocol.TypeHeartbeat, Status: "idle",
		Stats:                       protocol.HeartbeatStats{},
		PrefixCacheStatuses:         &replacement,
		PrefixCacheDonationOutcomes: &sixOutcomes,
	})
	waitFor(t, 2*time.Second, "cache telemetry state", func() bool {
		return reg.ProviderCount() == 1 &&
			reg.PrefixCacheProtocolStatus().ByReason["scan_pending"] == 1 &&
			reg.CacheRoutingLifecycleStatus().DonationOutcomes["donated"] == 4
	})

	empty := []protocol.PrefixCacheModelStatus{}
	writeProviderJSON(t, ctx, conn, protocol.HeartbeatMessage{
		Type: protocol.TypeHeartbeat, Status: "idle",
		Stats:                       protocol.HeartbeatStats{},
		PrefixCacheStatuses:         &empty,
		PrefixCacheDonationOutcomes: &sixOutcomes,
	})
	waitFor(t, 2*time.Second, "cache telemetry state", func() bool {
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
	waitFor(t, 2*time.Second, "cache telemetry state", func() bool { return reg.ProviderCount() == 0 })
	if got := reg.PrefixCacheProtocolStatus().LoadedModels; got != 0 {
		t.Fatalf("disconnect retained loaded status: %d", got)
	}
}

func TestStructuralOptionalCacheTelemetryDoesNotCloseRegistration(t *testing.T) {
	logger := slog.New(slog.DiscardHandler)
	reg := registry.New(logger)
	reg.SetModelCatalog([]registry.CatalogEntry{{ID: "public-model"}})
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

	oversizedStatuses := make([]protocol.PrefixCacheModelStatus, 17)
	duplicateOutcomes := []protocol.PrefixCacheDonationOutcomeCount{
		{Outcome: "donated", Count: 1},
		{Outcome: "donated", Count: 2},
	}
	writeProviderJSON(t, ctx, conn, protocol.RegisterMessage{
		Type:                        protocol.TypeRegister,
		Models:                      []protocol.ModelInfo{{ID: "owner-local"}},
		Backend:                     "mlx-swift",
		PrefixCacheProtocol:         1,
		PrefixCacheStatuses:         &oversizedStatuses,
		PrefixCacheDonationOutcomes: &duplicateOutcomes,
	})
	waitFor(t, 2*time.Second, "cache telemetry state", func() bool { return reg.ProviderCount() == 1 })
	status := reg.PrefixCacheProtocolStatus()
	if status.ReportedLoadedModels != 0 ||
		reg.CacheRoutingLifecycleStatus().DonationOutcomes["donated"] != 0 {
		t.Fatalf("structural telemetry was not dropped: providers=%+v lifecycle=%+v",
			status, reg.CacheRoutingLifecycleStatus())
	}

	// A subsequent heartbeat proves the provider socket remained usable.
	writeProviderJSON(t, ctx, conn, protocol.HeartbeatMessage{
		Type: protocol.TypeHeartbeat, Status: "idle", Stats: protocol.HeartbeatStats{},
	})
	time.Sleep(25 * time.Millisecond)
	if reg.ProviderCount() != 1 {
		t.Fatal("optional structural telemetry closed provider registration")
	}
}

func TestReadyCacheStatusHeartbeatReconcilesWithCapabilities(t *testing.T) {
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

	capability := cacheEligibilityV2Capability("model")
	ready := protocol.PrefixCacheModelStatus{
		ModelID: capability.ModelID, Backend: "contiguous", ReplayStrategy: "direct",
		State: "ready", Reason: "ready",
	}
	statuses := []protocol.PrefixCacheModelStatus{ready}
	writeProviderJSON(t, ctx, conn, protocol.RegisterMessage{
		Type: protocol.TypeRegister,
		Models: []protocol.ModelInfo{{
			ID: capability.ModelID, WeightHash: capability.ModelAggregateHash,
		}},
		Backend:             "mlx-swift",
		PrefixCacheProtocol: 2,
		PrefixCacheV2Models: []protocol.PrefixCacheV2Capability{capability},
		PrefixCacheStatuses: &statuses,
	})
	waitFor(t, 2*time.Second, "cache telemetry state", func() bool {
		status := reg.PrefixCacheProtocolStatus()
		return status.V2ReadyModels == 1 && status.ByState["ready"] == 1
	})

	capacity := &protocol.BackendCapacity{Slots: []protocol.BackendSlotCapacity{{
		Model: capability.ModelID, State: "idle",
	}}}
	pending := []protocol.PrefixCacheModelStatus{{
		ModelID: capability.ModelID, Backend: "contiguous", ReplayStrategy: "direct",
		State: "pending", Reason: "scan_pending",
	}}
	writeProviderJSON(t, ctx, conn, protocol.HeartbeatMessage{
		Type: protocol.TypeHeartbeat, Status: "idle", Stats: protocol.HeartbeatStats{},
		PrefixCacheStatuses: &pending, BackendCapacity: capacity,
	})
	waitFor(t, 2*time.Second, "cache telemetry state", func() bool {
		status := reg.PrefixCacheProtocolStatus()
		return status.V2ReadyModels == 1 &&
			status.ReportedLoadedModels == 0 &&
			status.UnreportedLoadedModels == 1
	})

	restored := []protocol.PrefixCacheModelStatus{ready}
	writeProviderJSON(t, ctx, conn, protocol.HeartbeatMessage{
		Type: protocol.TypeHeartbeat, Status: "idle", Stats: protocol.HeartbeatStats{},
		PrefixCacheStatuses: &restored, BackendCapacity: capacity,
	})
	waitFor(t, 2*time.Second, "cache telemetry state", func() bool {
		return reg.PrefixCacheProtocolStatus().ByState["ready"] == 1
	})

	emptyCapabilities := []protocol.PrefixCacheV2Capability{}
	readyOnV1 := []protocol.PrefixCacheModelStatus{ready}
	writeProviderJSON(t, ctx, conn, protocol.HeartbeatMessage{
		Type: protocol.TypeHeartbeat, Status: "idle", Stats: protocol.HeartbeatStats{},
		PrefixCacheProtocol: 1,
		PrefixCacheV2Models: &emptyCapabilities,
		PrefixCacheStatuses: &readyOnV1,
		BackendCapacity:     capacity,
	})
	waitFor(t, 2*time.Second, "cache telemetry state", func() bool {
		status := reg.PrefixCacheProtocolStatus()
		return status.V1 == 1 &&
			status.V2ReadyModels == 0 &&
			status.ReportedLoadedModels == 0
	})
}

func cacheEligibilityV2Capability(modelID string) protocol.PrefixCacheV2Capability {
	return protocol.PrefixCacheV2Capability{
		ModelID:            modelID,
		ModelAggregateHash: strings.Repeat("a", 64),
		PromptContractID:   strings.Repeat("b", 64),
		BlockHashVersion:   promptcontract.BlockHashVersion,
		BlockSize:          promptcontract.BlockSize,
		CacheEpoch:         "11111111-1111-1111-1111-111111111111",
		Enabled:            true,
		Ready:              true,
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
