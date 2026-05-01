package protocol

import (
	"encoding/json"
	"testing"
)

func TestHeartbeatNetworkQualityRoundTrip(t *testing.T) {
	msg := HeartbeatMessage{
		Type:   TypeHeartbeat,
		Status: "idle",
		Stats:  HeartbeatStats{},
		NetworkQuality: NetworkQuality{
			RTTMs:                  125.5,
			JitterMs:               42.25,
			ReconnectCount:         3,
			WebSocketWriteFailures: 2,
			LastWriteLatencyMs:     17.75,
		},
	}

	data, err := json.Marshal(msg)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	var decoded HeartbeatMessage
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	if decoded.NetworkQuality.RTTMs != 125.5 {
		t.Fatalf("rtt_ms=%f, want 125.5", decoded.NetworkQuality.RTTMs)
	}
	if decoded.NetworkQuality.JitterMs != 42.25 {
		t.Fatalf("jitter_ms=%f, want 42.25", decoded.NetworkQuality.JitterMs)
	}
	if decoded.NetworkQuality.ReconnectCount != 3 {
		t.Fatalf("reconnect_count=%d, want 3", decoded.NetworkQuality.ReconnectCount)
	}
	if decoded.NetworkQuality.WebSocketWriteFailures != 2 {
		t.Fatalf("websocket_write_failures=%d, want 2", decoded.NetworkQuality.WebSocketWriteFailures)
	}
	if decoded.NetworkQuality.LastWriteLatencyMs != 17.75 {
		t.Fatalf("last_write_latency_ms=%f, want 17.75", decoded.NetworkQuality.LastWriteLatencyMs)
	}
}

func TestHeartbeatMissingNetworkQualityDefaultsToZero(t *testing.T) {
	raw := `{"type":"heartbeat","status":"idle","active_model":null,"stats":{"requests_served":0,"tokens_generated":0}}`

	var pm ProviderMessage
	if err := json.Unmarshal([]byte(raw), &pm); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	hb := pm.Payload.(*HeartbeatMessage)
	if hb.NetworkQuality != (NetworkQuality{}) {
		t.Fatalf("NetworkQuality=%+v, want zero value", hb.NetworkQuality)
	}
}
