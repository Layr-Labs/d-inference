package api

import (
	"context"
	"encoding/json"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"nhooyr.io/websocket"
	"testing"
	"time"
)

// TestProviderReadLoopRejectsMalformedFramesAndKeepsConnection: the read loop
// decodes each frame once (ProviderMessage.UnmarshalJSON directly); invalid
// JSON, an unknown type and a type-mismatched payload are still rejected
// without dropping the connection, and the next valid heartbeat is processed.
func TestProviderReadLoopRejectsMalformedFramesAndKeepsConnection(t *testing.T) {
	_, reg, _, ts := setupTestServer(t)
	defer ts.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	pubKey := testPublicKeyB64()
	const model = "frame-decode-model"
	conn := connectProvider(t, ctx, ts.URL, []protocol.ModelInfo{{ID: model, ModelType: "chat"}}, pubKey)
	defer conn.Close(websocket.StatusNormalClosure, "")
	ids := reg.ProviderIDs()
	if len(ids) != 1 {
		t.Fatalf("registered providers = %d, want 1", len(ids))
	}
	p := reg.GetProvider(ids[0])
	if p == nil {
		t.Fatal("provider not in registry")
	}
	// Drain coordinator frames (challenges) so the socket never backs up.
	go func() {
		for {
			if _, _, err := conn.Read(ctx); err != nil {
				return
			}
		}
	}()

	p.Mu().Lock()
	before := p.LastHeartbeat
	p.Mu().Unlock()
	time.Sleep(10 * time.Millisecond)

	for _, frame := range []string{
		`this is not json`,
		`{"type":"no_such_message_type","x":1}`,
		`{"type":"heartbeat","status":123}`,
		`{"type":"heartbeat"`,
	} {
		if err := conn.Write(ctx, websocket.MessageText, []byte(frame)); err != nil {
			t.Fatalf("write %q: %v", frame, err)
		}
	}
	// A valid heartbeat after the bad frames proves the loop kept reading.
	hb, _ := json.Marshal(protocol.HeartbeatMessage{
		Type: protocol.TypeHeartbeat, Status: "online",
		SystemMetrics: protocol.SystemMetrics{ThermalState: "nominal"},
	})
	if err := conn.Write(ctx, websocket.MessageText, hb); err != nil {
		t.Fatalf("write heartbeat: %v", err)
	}
	deadline := time.Now().Add(3 * time.Second)
	for {
		p.Mu().Lock()
		advanced := p.LastHeartbeat.After(before)
		p.Mu().Unlock()
		if advanced {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("heartbeat after malformed frames was not processed (read loop stopped or connection dropped)")
		}
		time.Sleep(5 * time.Millisecond)
	}
	if reg.GetProvider(ids[0]) == nil {
		t.Fatal("provider was disconnected by malformed frames")
	}
}
