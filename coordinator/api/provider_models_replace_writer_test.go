package api

import (
	"context"
	"encoding/json"
	"reflect"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"nhooyr.io/websocket"
)

func readReplacementFrame(t *testing.T, ctx context.Context, peer *websocket.Conn, want string, target any) {
	t.Helper()
	_, data, err := peer.Read(ctx)
	if err != nil {
		t.Fatal(err)
	}
	var envelope struct {
		Type string `json:"type"`
	}
	if err := json.Unmarshal(data, &envelope); err != nil || envelope.Type != want {
		t.Fatalf("wanted %s, got %s (%v)", want, data, err)
	}
	if target != nil {
		if err := json.Unmarshal(data, target); err != nil {
			t.Fatal(err)
		}
	}
}

func TestModelsReplaceFailedAckKeepsRoutingFencedAndQueuesUntouched(t *testing.T) {
	s, p, peer := dispatchAccountingProvider(t)
	s.registry.SetModelCatalog([]registry.CatalogEntry{{ID: dispatchAccountingModel}, {ID: "replacement"}})
	generation := s.registry.CommitProviderDrain(p, "drain")
	if !s.registry.CompleteProviderDrain(p, "drain", generation) {
		t.Fatal("drain did not settle")
	}
	queued := []*registry.QueuedRequest{
		{RequestID: "old", Model: dispatchAccountingModel, Pending: &registry.PendingRequest{RequestID: "old", Model: dispatchAccountingModel}},
		{RequestID: "new", Model: "replacement", Pending: &registry.PendingRequest{RequestID: "new", Model: "replacement"}},
	}
	for _, request := range queued {
		if err := s.registry.Queue().Enqueue(request); err != nil {
			t.Fatal(err)
		}
	}
	// The actual writer rejects this receipt before handoff without closing
	// the healthy socket. Inventory must commit, but admission must not resume.
	failedCtx, fail := context.WithCancel(context.Background())
	fail()
	s.handleModelsReplace(failedCtx, p, &protocol.ModelsReplaceMessage{
		RequestID: "replace", DrainRequestID: "drain", Models: []protocol.ModelInfo{{ID: "replacement"}},
	})
	if s.registry.GetProvider(p.ID) != p || !s.registry.ProviderDraining(p.ID) || p.PendingCount() != 0 {
		t.Fatal("failed receipt reopened or disconnected the live session")
	}
	p.Mu().Lock()
	models := append([]protocol.ModelInfo(nil), p.Models...)
	p.Mu().Unlock()
	if len(models) != 1 || models[0].ID != "replacement" {
		t.Fatalf("expected committed inventory behind the fence, got %+v", models)
	}
	for _, request := range queued {
		if s.registry.Queue().QueueSize(request.Model) != 1 {
			t.Fatalf("failed receipt drained/rejected queued %s", request.Model)
		}
		select {
		case <-request.ResponseCh:
			t.Fatalf("failed receipt dispatched/rejected queued %s", request.Model)
		default:
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := p.WriteTextControl(ctx, []byte(`{"type":"still_connected"}`)); err != nil {
		t.Fatal(err)
	}
	readReplacementFrame(t, ctx, peer, "still_connected", nil)
	// A fresh barrier permits explicit reconciliation on the same socket.
	generation = s.registry.CommitProviderDrain(p, "reconcile")
	s.registry.CompleteProviderDrain(p, "reconcile", generation)
	s.handleModelsReplace(ctx, p, &protocol.ModelsReplaceMessage{
		RequestID: "retry", DrainRequestID: "reconcile", Models: models,
	})
	var receipt protocol.ModelsReplaceAckMessage
	readReplacementFrame(t, ctx, peer, protocol.TypeModelsReplaceAck, &receipt)
	if !receipt.Accepted || receipt.RequestID != "retry" || s.registry.ProviderDraining(p.ID) {
		t.Fatalf("same-session reconciliation failed: %+v", receipt)
	}
	select {
	case selected := <-queued[1].ResponseCh:
		if selected != p {
			t.Fatal("reconciled replacement did not receive queued work")
		}
	case <-ctx.Done():
		t.Fatal("successful receipt did not dispatch queued replacement work")
	}
}

func TestModelsReplaceRefreshesDesiredSnapshotAfterAck(t *testing.T) {
	for _, lineage := range []string{"previous", "retired", "deselected"} {
		t.Run(lineage, func(t *testing.T) {
			s, p, peer := dispatchAccountingProvider(t)
			p.Mu().Lock()
			p.Version = minProviderVersionForDesiredModels
			p.Mu().Unlock()
			s.registry.SetModelCatalog([]registry.CatalogEntry{
				{ID: dispatchAccountingModel}, {ID: "desired"}, {ID: "previous"}, {ID: "selected"},
				{ID: "protected", RequiredProviderCapabilities: []string{"unavailable"}},
			})
			alias := registry.AliasTarget{Desired: "desired", Previous: dispatchAccountingModel}
			if lineage == "retired" {
				alias.Previous = "previous"
				alias.Retired = []string{dispatchAccountingModel}
			}
			s.registry.SetModelAliases(map[string]registry.AliasTarget{
				"public":     alias,
				"ineligible": {Desired: "protected", Previous: dispatchAccountingModel},
			})
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			s.fanOutDesiredModels()
			var before protocol.DesiredModelsMessage
			readReplacementFrame(t, ctx, peer, protocol.TypeDesiredModels, &before)
			want := []protocol.DesiredModelEntry{{ModelName: "public", DesiredBuild: "desired", PreviousBuild: alias.Previous}}
			if !reflect.DeepEqual(before.Models, want) {
				t.Fatalf("initial desired snapshot = %+v, want %+v", before.Models, want)
			}
			generation := s.registry.CommitProviderDrain(p, "drain")
			s.registry.CompleteProviderDrain(p, "drain", generation)
			models := []protocol.ModelInfo{{ID: dispatchAccountingModel}, {ID: "selected"}}
			if lineage == "deselected" {
				models = []protocol.ModelInfo{{ID: "selected"}}
				want = []protocol.DesiredModelEntry{}
			}
			s.handleModelsReplace(ctx, p, &protocol.ModelsReplaceMessage{RequestID: "replace", DrainRequestID: "drain", Models: models})
			var receipt protocol.ModelsReplaceAckMessage
			readReplacementFrame(t, ctx, peer, protocol.TypeModelsReplaceAck, &receipt)
			if !receipt.Accepted || receipt.ValidateOnly || receipt.RequestID != "replace" {
				t.Fatalf("replacement failed: %+v", receipt)
			}
			var after protocol.DesiredModelsMessage
			readReplacementFrame(t, ctx, peer, protocol.TypeDesiredModels, &after)
			if !reflect.DeepEqual(after.Models, want) {
				t.Fatalf("post-ack snapshot = %+v, want %+v", after.Models, want)
			}
		})
	}
}
