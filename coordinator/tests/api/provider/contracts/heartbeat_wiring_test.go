package provider_test

import (
	"context"
	"encoding/json"
	"net"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/datadog"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/tests/internal/testkit"
	"nhooyr.io/websocket"
)

func TestProviderHeartbeatSessionUsesLiveRegistryAndObservation(t *testing.T) {
	srv, reg, _, ts := setupTestServer(t)
	srv.SetChallengeInterval(time.Hour)
	udp, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer udp.Close()
	dd, err := datadog.NewClient(datadog.Config{StatsdAddr: udp.LocalAddr().String(), FlushSecs: 60}, quietLogger())
	if err != nil {
		t.Fatal(err)
	}
	defer dd.Close()
	srv.SetDatadog(dd)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	const model = "heartbeat-wiring-model"
	pub := testkit.PublicKeyB64()
	conn := testkit.ConnectProvider(t, ctx, ts.URL, []protocol.ModelInfo{{ID: model, ModelType: "chat"}}, pub)
	defer conn.CloseNow()
	testkit.WaitForChallenge(t, ctx, conn, pub)

	active := model
	heartbeat, err := json.Marshal(protocol.HeartbeatMessage{
		Type: protocol.TypeHeartbeat, Status: "idle", ActiveModel: &active, WarmModels: []string{model},
		BackendCapacity: &protocol.BackendCapacity{
			CapacitySeq: 2, GPUMemoryActiveGB: 8,
			Slots: []protocol.BackendSlotCapacity{{Model: model, State: "idle", WedgeSuspected: true, EvalInFlightMs: 3000}},
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := conn.Write(ctx, websocket.MessageText, heartbeat); err != nil {
		t.Fatal(err)
	}
	// This ordered protocol barrier proves the live session completed heartbeat
	// ingestion and telemetry before the test reads either result.
	if err := conn.Write(ctx, websocket.MessageText, []byte(`{"type":"provider_drain","request_id":"heartbeat-observed"}`)); err != nil {
		t.Fatal(err)
	}
	for {
		_, data, err := conn.Read(ctx)
		if err != nil {
			t.Fatal(err)
		}
		var message struct {
			Type      string `json:"type"`
			RequestID string `json:"request_id"`
		}
		if err := json.Unmarshal(data, &message); err != nil {
			t.Fatal(err)
		}
		if message.Type == protocol.TypeAttestationChallenge {
			if err := conn.Write(ctx, websocket.MessageText, testkit.MakeValidChallengeResponse(data, pub)); err != nil {
				t.Fatal(err)
			}
		}
		if message.Type == protocol.TypeProviderDrainAck && message.RequestID == "heartbeat-observed" {
			break
		}
	}
	providers := reg.ListProviders()
	if len(providers) != 1 {
		t.Fatalf("live providers = %d, want 1", len(providers))
	}
	capacity := reg.GetProvider(providers[0].ID).BackendCapacitySnapshot()
	if capacity == nil || capacity.CapacitySeq != 2 || capacity.GPUMemoryActiveGB != 8 ||
		len(capacity.Slots) != 1 || capacity.Slots[0].Model != model || !capacity.Slots[0].WedgeSuspected {
		t.Fatalf("WebSocket heartbeat did not reach the live registry: %+v", capacity)
	}
	if err := dd.Statsd.Flush(); err != nil {
		t.Fatal(err)
	}
	if err := udp.SetReadDeadline(time.Now().Add(3 * time.Second)); err != nil {
		t.Fatal(err)
	}
	wedge, eval := false, false
	buf := make([]byte, 65536)
	for !wedge || !eval {
		n, _, err := udp.ReadFrom(buf)
		if err != nil {
			t.Fatalf("live heartbeat observation missing: wedge=%v eval=%v: %v", wedge, eval, err)
		}
		for _, line := range strings.Split(string(buf[:n]), "\n") {
			wedge = wedge || strings.Contains(line, "provider.first_token_wedge_suspected:1|c|") && strings.Contains(line, "model:"+model)
			eval = eval || strings.Contains(line, "provider.eval_in_flight_long:1|c")
		}
	}
}
