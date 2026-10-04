package provider_test

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

func applyReplacementCapacity(t *testing.T, s *Owner, p *registry.Provider, model string) {
	t.Helper()
	free := 24.0
	msg := &protocol.HeartbeatMessage{Status: "idle", BackendCapacity: &protocol.BackendCapacity{
		CapacitySeq:   1,
		FreeForLoadGB: &free,
		Slots:         []protocol.BackendSlotCapacity{{Model: model, State: "idle"}},
	}}
	if !s.heartbeat.Apply(p.ID, p, msg) {
		t.Fatal("fresh replacement heartbeat was rejected")
	}
	s.inventory.Heartbeat(context.Background(), p)
}

func TestModelsReplaceFailedAckKeepsRoutingFencedAndQueuesUntouched(t *testing.T) {
	s, p, peer := connectedTestProvider(t)
	s.registry.SetModelCatalog([]registry.CatalogEntry{{ID: testTransportModel}, {ID: "replacement"}})
	generation := s.registry.CommitProviderDrain(p, "drain")
	if !s.registry.CompleteProviderDrain(p, "drain", generation) {
		t.Fatal("drain did not settle")
	}
	queued := []*registry.QueuedRequest{
		{RequestID: "old", Model: testTransportModel, Pending: &registry.PendingRequest{RequestID: "old", Model: testTransportModel}},
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
	s.inventory.Replace(failedCtx, p, &protocol.ModelsReplaceMessage{
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
	s.inventory.Ready(context.Background(), p, &protocol.ModelsReplaceReadyMessage{RequestID: "replace", DrainRequestID: "drain", CapacitySeq: 1})
	if !s.registry.ProviderDraining(p.ID) {
		t.Fatal("readiness without a written commit receipt reopened admission")
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
	s.inventory.Replace(ctx, p, &protocol.ModelsReplaceMessage{
		RequestID: "retry", DrainRequestID: "reconcile", Models: models,
	})
	var receipt protocol.ModelsReplaceAckMessage
	readReplacementFrame(t, ctx, peer, protocol.TypeModelsReplaceAck, &receipt)
	if !receipt.Accepted || receipt.RequestID != "retry" || !s.registry.ProviderDraining(p.ID) {
		t.Fatalf("same-session reconciliation failed: %+v", receipt)
	}
	s.inventory.Ready(context.Background(), p, &protocol.ModelsReplaceReadyMessage{RequestID: "retry", DrainRequestID: "reconcile", CapacitySeq: 1})
	if !s.registry.ProviderDraining(p.ID) || s.registry.Queue().QueueSize("replacement") != 1 {
		t.Fatal("readiness dispatched before refreshed capacity")
	}
	applyReplacementCapacity(t, s, p, "replacement")
	if s.registry.ProviderDraining(p.ID) {
		t.Fatal("matching provider readiness and capacity failed to resume admission")
	}
	// Resuming admission refreshes the Swift provider's desired_models
	// snapshot before the receipt.
	readReplacementFrame(t, ctx, peer, protocol.TypeDesiredModels, nil)
	var resumed protocol.ModelsReplaceResumedMessage
	readReplacementFrame(t, ctx, peer, protocol.TypeModelsReplaceResumed, &resumed)
	if resumed.RequestID != "retry" || resumed.DrainRequestID != "reconcile" || resumed.CapacitySeq != 1 {
		t.Fatalf("wrong routing-resumed receipt: %+v", resumed)
	}
	select {
	case selected := <-queued[1].ResponseCh:
		if selected != p {
			t.Fatal("reconciled replacement did not receive queued work")
		}
	case <-ctx.Done():
		t.Fatal("successful receipt did not dispatch queued replacement work")
	}
	select {
	case selected := <-queued[0].ResponseCh:
		if selected != nil {
			t.Fatal("removed model queue unexpectedly dispatched to the replacement provider")
		}
	case <-ctx.Done():
		t.Fatal("removed model queue was not reconciled after the retry drain")
	}
}

func TestModelsReplaceResumedReceiptCanBeRetriedAfterWriteFailure(t *testing.T) {
	s, p, peer := connectedTestProvider(t)
	generation := s.registry.CommitProviderDrain(p, "drain")
	if !s.registry.CompleteProviderDrain(p, "drain", generation) {
		t.Fatal("drain did not settle")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	s.inventory.Replace(ctx, p, &protocol.ModelsReplaceMessage{
		RequestID: "replace", DrainRequestID: "drain", Models: append([]protocol.ModelInfo(nil), p.Models...),
	})
	readReplacementFrame(t, ctx, peer, protocol.TypeModelsReplaceAck, nil)
	free := 24.0
	if !s.heartbeat.Apply(p.ID, p, &protocol.HeartbeatMessage{
		Status: "idle", BackendCapacity: &protocol.BackendCapacity{CapacitySeq: 1, FreeForLoadGB: &free},
	}) {
		t.Fatal("fresh capacity was not applied")
	}
	ready := &protocol.ModelsReplaceReadyMessage{RequestID: "replace", DrainRequestID: "drain", CapacitySeq: 1}
	failedCtx, fail := context.WithCancel(context.Background())
	fail()
	s.inventory.Ready(failedCtx, p, ready)
	if s.registry.ProviderDraining(p.ID) {
		t.Fatal("failed resumed-ack write re-fenced routing")
	}
	// The failed attempt still refreshed desired_models before its receipt
	// write failed. An identical frame on this session resends only the
	// receipt; it does not repeat the inventory, queue or desired transition.
	readReplacementFrame(t, ctx, peer, protocol.TypeDesiredModels, nil)
	s.inventory.Ready(ctx, p, ready)
	var resumed protocol.ModelsReplaceResumedMessage
	readReplacementFrame(t, ctx, peer, protocol.TypeModelsReplaceResumed, &resumed)
	if resumed.RequestID != ready.RequestID || resumed.DrainRequestID != ready.DrainRequestID ||
		resumed.CapacitySeq != ready.CapacitySeq {
		t.Fatalf("retry did not receive the matching receipt: %+v", resumed)
	}
	if next := s.registry.CommitProviderDrain(p, "new-drain"); next == 0 {
		t.Fatal("new barrier failed")
	}
	if _, _, resumedAgain, ack := s.registry.ResumeProviderModels(p, ready.RequestID, ready.DrainRequestID, ready.CapacitySeq); resumedAgain || ack != nil {
		t.Fatal("old readiness was acknowledged after a newer drain")
	}
}

func TestModelsReplaceRefreshesDesiredSnapshotAfterAck(t *testing.T) {
	for _, lineage := range []string{"previous", "retired", "deselected"} {
		t.Run(lineage, func(t *testing.T) {
			s, p, peer := connectedTestProvider(t)
			s.registry.SetModelCatalog([]registry.CatalogEntry{
				{ID: testTransportModel}, {ID: "desired"}, {ID: "previous"}, {ID: "selected"},
				{ID: "protected", RequiredProviderCapabilities: []string{"unavailable"}},
			})
			alias := registry.AliasTarget{Desired: "desired", Previous: testTransportModel}
			if lineage == "retired" {
				alias.Previous = "previous"
				alias.Retired = []string{testTransportModel}
			}
			s.registry.SetModelAliases(map[string]registry.AliasTarget{
				"public":     alias,
				"ineligible": {Desired: "protected", Previous: testTransportModel},
			})
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			s.catalog.FanOutDesiredModels()
			var before protocol.DesiredModelsMessage
			readReplacementFrame(t, ctx, peer, protocol.TypeDesiredModels, &before)
			want := []protocol.DesiredModelEntry{{ModelName: "public", DesiredBuild: "desired", PreviousBuild: alias.Previous}}
			if !reflect.DeepEqual(before.Models, want) {
				t.Fatalf("initial desired snapshot = %+v, want %+v", before.Models, want)
			}
			generation := s.registry.CommitProviderDrain(p, "drain")
			s.registry.CompleteProviderDrain(p, "drain", generation)
			models := []protocol.ModelInfo{{ID: testTransportModel}, {ID: "selected"}}
			if lineage == "deselected" {
				models = []protocol.ModelInfo{{ID: "selected"}}
				want = []protocol.DesiredModelEntry{}
			}
			s.inventory.Replace(ctx, p, &protocol.ModelsReplaceMessage{RequestID: "replace", DrainRequestID: "drain", Models: models})
			var receipt protocol.ModelsReplaceAckMessage
			readReplacementFrame(t, ctx, peer, protocol.TypeModelsReplaceAck, &receipt)
			if !receipt.Accepted || receipt.ValidateOnly || receipt.RequestID != "replace" {
				t.Fatalf("replacement failed: %+v", receipt)
			}
			if !s.registry.ProviderDraining(p.ID) {
				t.Fatal("receipt reopened admission before provider readiness")
			}
			s.inventory.Ready(context.Background(), p, &protocol.ModelsReplaceReadyMessage{RequestID: "replace", DrainRequestID: "drain", CapacitySeq: 1})
			applyReplacementCapacity(t, s, p, "selected")
			var after protocol.DesiredModelsMessage
			readReplacementFrame(t, ctx, peer, protocol.TypeDesiredModels, &after)
			if !reflect.DeepEqual(after.Models, want) {
				t.Fatalf("post-ack snapshot = %+v, want %+v", after.Models, want)
			}
		})
	}
}
