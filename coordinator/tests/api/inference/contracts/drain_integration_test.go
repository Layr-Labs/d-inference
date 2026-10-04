package inference_test

// Provider heartbeat drain awareness through the real HTTP + WebSocket path:
// routing skips draining providers, counts their capacity as transient, and
// restores routing when a provider returns to idle.

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"nhooyr.io/websocket"
)

// sendHeartbeatStatus emits a heartbeat with the given status from the fake
// provider's socket (the same frame a Swift provider sends every ~30s).
func (fp *failoverProvider) sendHeartbeatStatus(t *testing.T, ctx context.Context, status string) {
	t.Helper()
	data, err := json.Marshal(protocol.HeartbeatMessage{
		Type: protocol.TypeHeartbeat, Status: status, Stats: protocol.HeartbeatStats{},
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := fp.conn.Write(ctx, websocket.MessageText, data); err != nil {
		t.Fatal(err)
	}
}

// TestDrain_HeartbeatStatusSkipsProvider: the fast provider A reports
// "draining"; the admission preflight counts it as transient capacity, the
// request is served by B without ever touching A, and an "idle" heartbeat
// restores A.
func TestDrain_HeartbeatStatusSkipsProvider(t *testing.T) {
	reg, _, ts := setupFailoverServer(t)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	model := "drain-heartbeat-model"

	pA := startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
		Name: "provider-a", Version: "0.9.0", DecodeTPS: 200,
		Models: []failoverModelSpec{{ID: model}}, Script: fullServeScript(model),
	})
	pB := startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
		Name: "provider-b", Version: "0.9.0", DecodeTPS: 1,
		Models: []failoverModelSpec{{ID: model}}, Script: fullServeScript(model),
	})

	pA.sendHeartbeatStatus(t, ctx, protocol.HeartbeatStatusDraining)
	awaitCondition(t, 5*time.Second, func() bool { return reg.ProviderDraining(pA.registryID) }, "provider-a marked draining by its heartbeat")

	candidates, capacityRejections, tooLarge := reg.QuickCapacityCheck(model, 500, 64, registry.RequestTraits{})
	if candidates != 1 || capacityRejections != 1 || tooLarge != 0 {
		t.Errorf("QuickCapacityCheck = (%d, %d, %d), want (1, 1, 0): B routable, A transient", candidates, capacityRejections, tooLarge)
	}

	status, body, err := postChat(ctx, ts.URL, "test-key", buildChatBody(t, model, true, nil))
	if err != nil {
		t.Fatalf("chat request: %v", err)
	}
	assertCleanFailoverStream(t, status, body, markerFor("provider-b"))
	if got := pA.dispatchCount(); got != 0 {
		t.Errorf("draining provider-a received %d dispatch(es), want 0", got)
	}

	pA.sendHeartbeatStatus(t, ctx, "idle")
	awaitCondition(t, 5*time.Second, func() bool { return !reg.ProviderDraining(pA.registryID) }, "provider-a drain cleared by an idle heartbeat")
	status, body, err = postChat(ctx, ts.URL, "test-key", buildChatBody(t, model, true, nil))
	if err != nil {
		t.Fatalf("chat request after drain cleared: %v", err)
	}
	assertCleanFailoverStream(t, status, body, markerFor("provider-a"))
	if got := pB.dispatchCount(); got != 1 {
		t.Errorf("provider-b dispatches = %d, want 1", got)
	}
}
