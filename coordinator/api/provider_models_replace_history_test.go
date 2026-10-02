package api

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"nhooyr.io/websocket"
)

func TestProviderModelsReplaceRejectsUnconfirmedHistoryOverflow(t *testing.T) {
	srv, reg, _, ts := setupTestServer(t)
	srv.challengeInterval = time.Hour
	defer ts.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	// Three removed IDs exceed the 64 KiB session history budget while each
	// complete frame is far below the WebSocket read limit.
	id := func(c string) string { return strings.Repeat(c, 32*1024) }
	pub := testPublicKeyB64()
	conn := connectProvider(t, ctx, ts.URL, []protocol.ModelInfo{{ID: id("a")}}, pub)
	defer conn.CloseNow()
	waitForChallenge(t, ctx, conn, pub)
	read := func(want string, target any) {
		t.Helper()
		for {
			_, data, err := conn.Read(ctx)
			if err != nil {
				t.Fatal(err)
			}
			var envelope struct {
				Type string `json:"type"`
			}
			if err := json.Unmarshal(data, &envelope); err != nil {
				t.Fatal(err)
			}
			if envelope.Type == want {
				if err := json.Unmarshal(data, target); err != nil {
					t.Fatal(err)
				}
				return
			}
		}
	}
	write := func(msg any) {
		t.Helper()
		data, err := json.Marshal(msg)
		if err != nil {
			t.Fatal(err)
		}
		if err := conn.Write(ctx, websocket.MessageText, data); err != nil {
			t.Fatal(err)
		}
	}
	for _, next := range []string{"b", "c", "d"} {
		write(protocol.ProviderDrainMessage{Type: protocol.TypeProviderDrain, RequestID: next})
		var drain protocol.ProviderDrainMessage
		read(protocol.TypeProviderDrainAck, &drain)
		if drain.RequestID != next {
			t.Fatal("uncorrelated drain acknowledgement")
		}
		for _, validateOnly := range []bool{true, false} {
			write(protocol.ModelsReplaceMessage{
				Type: protocol.TypeModelsReplace, RequestID: next, DrainRequestID: next,
				ValidateOnly: validateOnly, Models: []protocol.ModelInfo{{ID: id(next)}},
			})
			var ack protocol.ModelsReplaceAckMessage
			read(protocol.TypeModelsReplaceAck, &ack)
			wantError := ""
			if next == "d" {
				wantError = "invalid_models"
			}
			if ack.RequestID != next || ack.DrainRequestID != next || ack.ValidateOnly != validateOnly ||
				ack.Accepted != (wantError == "") || ack.Error != wantError {
				t.Fatalf("wrong history budget acknowledgement: %+v", ack)
			}
		}
		// Omit models_replace_ready, then drain and replace again on this socket.
	}
	ids := reg.ProviderIDs()
	if len(ids) != 1 || !reg.ProviderDraining(ids[0]) {
		t.Fatal("overflow disconnected or reopened the registered session")
	}
	p := reg.GetProvider(ids[0])
	p.Mu().Lock()
	defer p.Mu().Unlock()
	if len(p.Models) != 1 || p.Models[0].ID != id("c") {
		t.Fatal("overflow changed the last accepted inventory")
	}
}
