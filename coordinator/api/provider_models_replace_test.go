package api

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"nhooyr.io/websocket"
)

func TestProviderModelsReplaceUsesSameDrainedConnection(t *testing.T) {
	srv, reg, _, ts := setupTestServer(t)
	// This scenario checks replacement, not periodic attestation refreshes.
	srv.challengeInterval = time.Hour
	defer ts.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	pub := testPublicKeyB64()
	conn := connectProvider(t, ctx, ts.URL, []protocol.ModelInfo{{ID: "old", ModelType: "chat"}}, pub)
	defer conn.CloseNow()
	waitForChallenge(t, ctx, conn, pub)
	ids := reg.ProviderIDs()
	if len(ids) != 1 {
		t.Fatalf("providers: %v", ids)
	}
	original := reg.GetProvider(ids[0])
	active := "old"
	reg.Heartbeat(original.ID, &protocol.HeartbeatMessage{
		Status: "idle", ActiveModel: &active, WarmModels: []string{"old"},
		BackendCapacity: &protocol.BackendCapacity{Slots: []protocol.BackendSlotCapacity{{Model: "old", State: "idle"}}},
	})
	readType := func(want string) []byte {
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
			if envelope.Type == protocol.TypeAttestationChallenge {
				if err := conn.Write(ctx, websocket.MessageText, makeValidChallengeResponse(data, pub)); err != nil {
					t.Fatal(err)
				}
			}
			if envelope.Type == want {
				return data
			}
		}
	}
	if err := conn.Write(ctx, websocket.MessageText, []byte(`{"type":"provider_drain","request_id":"drain"}`)); err != nil {
		t.Fatal(err)
	}
	readType(protocol.TypeProviderDrainAck)
	// The ordered barrier follows the initial challenge response, so capture
	// trust only after registration attestation has finished processing.
	makeProviderRoutable(reg)
	trust, challenge := original.GetTrustLevel(), original.GetLastChallengeVerified()
	queued := []*registry.QueuedRequest{
		{RequestID: "waiting-old", Model: "old", Pending: &registry.PendingRequest{RequestID: "waiting-old", Model: "old"}},
		{RequestID: "waiting-new", Model: "new", Pending: &registry.PendingRequest{RequestID: "waiting-new", Model: "new"}},
	}
	for _, request := range queued {
		if err := reg.Queue().Enqueue(request); err != nil {
			t.Fatal(err)
		}
	}
	cases := []struct {
		id           string
		drain        string
		validateOnly bool
		models       []protocol.ModelInfo
		wantError    string
	}{
		{"invalid-validation-drain", "wrong", true, []protocol.ModelInfo{{ID: "new"}}, "invalid_drain"},
		{"invalid-validation-models", "drain", true, []protocol.ModelInfo{{ID: "new"}, {ID: "new"}}, "invalid_models"},
		{"valid-validation", "drain", true, []protocol.ModelInfo{{ID: "new"}}, ""},
		{"invalid-commit-drain", "wrong", false, []protocol.ModelInfo{{ID: "new"}}, "invalid_drain"},
		{"valid-commit", "drain", false, []protocol.ModelInfo{{ID: "new"}}, ""},
	}
	for _, tc := range cases {
		request := protocol.ModelsReplaceMessage{Type: protocol.TypeModelsReplace, RequestID: tc.id, DrainRequestID: tc.drain, ValidateOnly: tc.validateOnly, Models: tc.models}
		data, err := json.Marshal(request)
		if err != nil {
			t.Fatal(err)
		}
		if err := conn.Write(ctx, websocket.MessageText, data); err != nil {
			t.Fatal(err)
		}
		var ack protocol.ModelsReplaceAckMessage
		if err := json.Unmarshal(readType(protocol.TypeModelsReplaceAck), &ack); err != nil {
			t.Fatal(err)
		}
		if ack.RequestID != request.RequestID || ack.DrainRequestID != tc.drain || ack.ValidateOnly != tc.validateOnly || ack.Accepted != (tc.wantError == "") || ack.Error != tc.wantError {
			t.Fatalf("uncorrelated or wrong result: %+v", ack)
		}
		if tc.validateOnly || !ack.Accepted {
			if !reg.ProviderDraining(original.ID) || reg.GetProvider(original.ID) != original || original.GetTrustLevel() != trust || original.GetLastChallengeVerified() != challenge {
				t.Fatal("validation/rejection changed live session trust or reopened drain")
			}
			if len(original.Models) != 1 || original.Models[0].ID != "old" || original.CurrentModel != "old" || len(original.WarmModels) != 1 || original.WarmModels[0] != "old" || len(original.BackendCapacity.Slots) != 1 || original.BackendCapacity.Slots[0].Model != "old" {
				t.Fatal("validation/rejection changed advertised or resident inventory")
			}
			for _, waiting := range queued {
				if reg.Queue().QueueSize(waiting.Model) != 1 {
					t.Fatalf("validation/rejection removed queued %s request", waiting.Model)
				}
				select {
				case <-waiting.ResponseCh:
					t.Fatalf("validation/rejection dispatched or rejected queued %s request", waiting.Model)
				default:
				}
			}
		}
	}
	if reg.GetProvider(original.ID) != original || reg.ProviderDraining(original.ID) {
		t.Fatal("replacement reset or failed to resume live session")
	}
}
