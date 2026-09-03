package protocol

import (
	"encoding/json"
	"strings"
	"testing"
)

// idle_unload_mins: 0 ("always ready") is a real policy and must survive
// omitempty; only an unreported policy (nil) is absent from the wire.
func TestHeartbeatIdleUnloadMinsRoundTrip(t *testing.T) {
	zero := 0
	msg := HeartbeatMessage{Type: TypeHeartbeat, Status: "idle", IdleUnloadMins: &zero}
	data, err := json.Marshal(msg)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if !strings.Contains(string(data), `"idle_unload_mins":0`) {
		t.Fatalf("always-ready policy dropped from the wire: %s", data)
	}
	var decoded HeartbeatMessage
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if decoded.IdleUnloadMins == nil || *decoded.IdleUnloadMins != 0 {
		t.Fatalf("idle_unload_mins = %v, want 0", decoded.IdleUnloadMins)
	}

	// Legacy provider: key absent → nil, never a defaulted value.
	var legacy HeartbeatMessage
	if err := json.Unmarshal([]byte(`{"type":"heartbeat","status":"idle"}`), &legacy); err != nil {
		t.Fatalf("unmarshal legacy: %v", err)
	}
	if legacy.IdleUnloadMins != nil {
		t.Fatalf("legacy heartbeat decoded idle_unload_mins = %d, want nil", *legacy.IdleUnloadMins)
	}
	out, err := json.Marshal(legacy)
	if err != nil {
		t.Fatalf("marshal legacy: %v", err)
	}
	if strings.Contains(string(out), "idle_unload_mins") {
		t.Fatalf("nil policy must be omitted, got %s", out)
	}
}
