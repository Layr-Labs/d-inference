package registry

import (
	"testing"

	"github.com/eigeninference/coordinator/internal/protocol"
)

func TestNetworkPenaltyDefaultsToZeroForMissingMetrics(t *testing.T) {
	if got := networkPenaltyMs(protocol.NetworkQuality{}); got != 0 {
		t.Fatalf("networkPenaltyMs(zero)=%f, want 0", got)
	}
}

func TestNetworkPenaltyDegradesHighLatencyAndInstability(t *testing.T) {
	good := protocol.NetworkQuality{RTTMs: 20, JitterMs: 5}
	bad := protocol.NetworkQuality{
		RTTMs:                  900,
		JitterMs:               250,
		ReconnectCount:         4,
		WebSocketWriteFailures: 3,
		LastWriteLatencyMs:     150,
	}

	goodPenalty := networkPenaltyMs(good)
	badPenalty := networkPenaltyMs(bad)
	if goodPenalty != 0 {
		t.Fatalf("good network penalty=%f, want 0 below thresholds", goodPenalty)
	}
	if badPenalty <= goodPenalty {
		t.Fatalf("bad penalty=%f, want > good penalty=%f", badPenalty, goodPenalty)
	}
	if badPenalty > networkQualityMaxPenaltyMs {
		t.Fatalf("bad penalty=%f exceeds max=%f", badPenalty, networkQualityMaxPenaltyMs)
	}
}

func TestReserveProviderPenalizesLowerNetworkQuality(t *testing.T) {
	reg := New(testLogger())
	model := "network-quality-model"
	good := makeSchedulerProvider(t, reg, "good-network", model, 100)
	bad := makeSchedulerProvider(t, reg, "bad-network", model, 100)

	bad.mu.Lock()
	bad.NetworkQuality = protocol.NetworkQuality{
		RTTMs:                  1000,
		JitterMs:               300,
		ReconnectCount:         5,
		WebSocketWriteFailures: 5,
		LastWriteLatencyMs:     250,
	}
	bad.mu.Unlock()

	selected, decision := reg.ReserveProviderEx(model, &PendingRequest{
		RequestID:          "network-quality-req",
		Model:              model,
		RequestedMaxTokens: 128,
	})
	if selected == nil {
		t.Fatal("ReserveProviderEx returned nil")
	}
	if selected.ID != good.ID {
		t.Fatalf("selected %q, want good-network; decision=%+v", selected.ID, decision)
	}
	if decision.NetworkMs != 0 {
		t.Fatalf("winning good provider NetworkMs=%f, want 0", decision.NetworkMs)
	}
}

func TestHeartbeatStoresNetworkQualityForRoutingSnapshot(t *testing.T) {
	reg := New(testLogger())
	model := "heartbeat-network-model"
	p := makeSchedulerProvider(t, reg, "heartbeat-network", model, 100)

	reg.Heartbeat(p.ID, &protocol.HeartbeatMessage{
		Type:   protocol.TypeHeartbeat,
		Status: "idle",
		Stats:  protocol.HeartbeatStats{},
		NetworkQuality: protocol.NetworkQuality{
			RTTMs:                  321,
			JitterMs:               45,
			ReconnectCount:         2,
			WebSocketWriteFailures: 1,
			LastWriteLatencyMs:     12,
		},
	})

	snap, ok := reg.snapshotProviderLocked(p, model, &PendingRequest{RequestID: "snap", Model: model})
	if !ok {
		t.Fatal("snapshotProviderLocked returned !ok")
	}
	if snap.networkQuality.RTTMs != 321 {
		t.Fatalf("snapshot RTTMs=%f, want 321", snap.networkQuality.RTTMs)
	}
}
