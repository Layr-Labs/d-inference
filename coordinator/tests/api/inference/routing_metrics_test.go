package inference_test

import (
	"fmt"
	"log/slog"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

func TestRoutingMetrics_SelectedEmitsDecisionAndCost(t *testing.T) {
	collector := newUDPCollector(t)
	defer collector.Close()

	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := memory.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)

	model := "test-routing-model"
	makeRoutableProvider(t, reg, "p1", model)

	pr := &registry.PendingRequest{
		RequestID:             "req-test-1",
		Model:                 model,
		EstimatedPromptTokens: 100,
		RequestedMaxTokens:    256,
		ChunkCh:               make(chan registry.ProviderChunk, 1),
		CompleteCh:            make(chan protocol.UsageInfo, 1),
		ErrorCh:               make(chan protocol.InferenceErrorMessage, 1),
	}

	srv := newComposedServer(reg, st, TestServerConfig{}, logger)
	t.Cleanup(srv.Close)
	ddClient := newTestDD(t, collector)
	defer ddClient.Close()
	srv.observation.SetDatadog(ddClient)

	provider, decision := reg.ReserveProviderEx(model, pr)
	if provider == nil {
		t.Fatal("ReserveProviderEx returned nil — provider not routable")
	}

	srv.observation.Incr("routing.decisions", []string{"model:" + model, "outcome:selected"})
	srv.observation.Incr("routing.provider_selected", []string{"provider_id:" + provider.ID, "model:" + model})
	srv.observation.Histogram("routing.cost_ms", decision.CostMs, []string{"model:" + model, "provider_id:" + provider.ID})
	if decision.EffectiveTPS > 0 {
		srv.observation.Gauge("routing.effective_decode_tps", decision.EffectiveTPS, []string{"provider_id:" + provider.ID})
	}

	_ = ddClient.Statsd.Flush()
	packets := collector.drain()

	if !hasMetric(packets, "routing.decisions") {
		t.Errorf("missing routing.decisions metric; got packets: %v", packets)
	}
	if !hasMetric(packets, "outcome:selected") {
		t.Errorf("missing outcome:selected tag; got packets: %v", packets)
	}
	if !hasMetric(packets, "routing.provider_selected") {
		t.Errorf("missing routing.provider_selected metric; got packets: %v", packets)
	}
	if !hasMetric(packets, "routing.cost_ms") {
		t.Errorf("missing routing.cost_ms metric; got packets: %v", packets)
	}
	if decision.EffectiveTPS > 0 && !hasMetric(packets, "routing.effective_decode_tps") {
		t.Errorf("missing routing.effective_decode_tps metric; got packets: %v", packets)
	}
}

func TestRoutingMetrics_NoProviderEmitsNoProvider(t *testing.T) {
	collector := newUDPCollector(t)
	defer collector.Close()

	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := memory.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)

	srv := newComposedServer(reg, st, TestServerConfig{}, logger)
	t.Cleanup(srv.Close)
	ddClient := newTestDD(t, collector)
	defer ddClient.Close()
	srv.observation.SetDatadog(ddClient)

	model := "nonexistent-model"
	pr := &registry.PendingRequest{
		RequestID:          "req-noprovider",
		Model:              model,
		RequestedMaxTokens: 256,
		ChunkCh:            make(chan registry.ProviderChunk, 1),
		CompleteCh:         make(chan protocol.UsageInfo, 1),
		ErrorCh:            make(chan protocol.InferenceErrorMessage, 1),
	}

	provider, decision := reg.ReserveProviderEx(model, pr)
	if provider != nil {
		t.Fatal("expected nil provider for nonexistent model")
	}

	outcome := "no_provider"
	if decision.CapacityRejections > 0 && decision.CandidateCount == 0 {
		outcome = "over_capacity"
	}
	srv.observation.Incr("routing.decisions", []string{"model:" + model, "outcome:" + outcome})

	_ = ddClient.Statsd.Flush()
	packets := collector.drain()

	if !hasMetric(packets, "routing.decisions") {
		t.Errorf("missing routing.decisions metric; got packets: %v", packets)
	}
	if !hasMetric(packets, "outcome:no_provider") {
		t.Errorf("missing outcome:no_provider tag; got packets: %v", packets)
	}
}

func TestRoutingMetrics_OverCapacityOutcome(t *testing.T) {
	collector := newUDPCollector(t)
	defer collector.Close()

	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := memory.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)

	model := "big-model"
	reg.SetModelCatalog([]registry.CatalogEntry{{ID: model, SizeGB: 128}})
	p := makeRoutableProvider(t, reg, "tiny-provider", model)
	// Force idle_shutdown so the gate checks full model weight fit, not just KV.
	p.Mu().Lock()
	p.BackendCapacity.Slots[0].State = "idle_shutdown"
	p.Mu().Unlock()

	srv := newComposedServer(reg, st, TestServerConfig{}, logger)
	t.Cleanup(srv.Close)
	ddClient := newTestDD(t, collector)
	defer ddClient.Close()
	srv.observation.SetDatadog(ddClient)

	pr := &registry.PendingRequest{
		RequestID:          "req-overcap",
		Model:              model,
		RequestedMaxTokens: 256,
		ChunkCh:            make(chan registry.ProviderChunk, 1),
		CompleteCh:         make(chan protocol.UsageInfo, 1),
		ErrorCh:            make(chan protocol.InferenceErrorMessage, 1),
	}

	provider, decision := reg.ReserveProviderEx(model, pr)
	if provider != nil {
		t.Fatal("expected nil — 64GB provider can't fit 128GB model")
	}

	// A model that can never fit must be classified as model_too_large, NOT
	// over_capacity. over_capacity emits a 429 + Retry-After telling the client
	// to retry, which is pointless when the model will never fit on this box —
	// the client would retry forever. The absolute-fit gate reports it via
	// ModelTooLargeRejections (permanent), separate from CapacityRejections
	// (transient: full now, retry later).
	if decision.ModelTooLargeRejections == 0 {
		t.Fatalf("expected ModelTooLargeRejections > 0 for a 128GB model on a 64GB provider; decision=%+v", decision)
	}
	if decision.CapacityRejections != 0 {
		t.Fatalf("a too-large model must not count as transient capacity pressure; got CapacityRejections=%d", decision.CapacityRejections)
	}

	outcome := "no_provider"
	if decision.ModelTooLargeRejections > 0 && decision.CandidateCount == 0 {
		outcome = "model_too_large"
	} else if decision.CapacityRejections > 0 && decision.CandidateCount == 0 {
		outcome = "over_capacity"
	}
	srv.observation.Incr("routing.decisions", []string{"model:" + model, "outcome:" + outcome})

	_ = ddClient.Statsd.Flush()
	packets := collector.drain()

	if !hasMetric(packets, "outcome:model_too_large") {
		t.Errorf("expected model_too_large outcome when provider too small; got packets: %v", packets)
	}
}

func TestRoutingMetrics_AllTagsOnSelection(t *testing.T) {
	collector := newUDPCollector(t)
	defer collector.Close()

	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := memory.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)

	model := "tag-check-model"
	p := makeRoutableProvider(t, reg, "tag-provider", model)

	srv := newComposedServer(reg, st, TestServerConfig{}, logger)
	t.Cleanup(srv.Close)
	ddClient := newTestDD(t, collector)
	defer ddClient.Close()
	srv.observation.SetDatadog(ddClient)

	pr := &registry.PendingRequest{
		RequestID:             fmt.Sprintf("req-tags-%d", time.Now().UnixNano()),
		Model:                 model,
		EstimatedPromptTokens: 50,
		RequestedMaxTokens:    128,
		ChunkCh:               make(chan registry.ProviderChunk, 1),
		CompleteCh:            make(chan protocol.UsageInfo, 1),
		ErrorCh:               make(chan protocol.InferenceErrorMessage, 1),
	}

	provider, decision := reg.ReserveProviderEx(model, pr)
	if provider == nil {
		t.Fatal("routing returned nil")
	}

	srv.observation.Incr("routing.decisions", []string{"model:" + model, "outcome:selected"})
	srv.observation.Incr("routing.provider_selected", []string{"provider_id:" + provider.ID, "model:" + model})
	srv.observation.Histogram("routing.cost_ms", decision.CostMs, []string{"model:" + model, "provider_id:" + provider.ID})
	srv.observation.Gauge("routing.effective_decode_tps", decision.EffectiveTPS, []string{"provider_id:" + provider.ID})

	_ = ddClient.Statsd.Flush()
	packets := collector.drain()

	checks := []struct {
		metric string
		tag    string
	}{
		{"routing.decisions", "model:" + model},
		{"routing.decisions", "outcome:selected"},
		{"routing.provider_selected", "provider_id:" + p.ID},
		{"routing.provider_selected", "model:" + model},
		{"routing.cost_ms", "model:" + model},
		{"routing.cost_ms", "provider_id:" + provider.ID},
		{"routing.effective_decode_tps", "provider_id:" + p.ID},
	}
	for _, c := range checks {
		matches := findMetrics(packets, c.metric)
		found := false
		for _, m := range matches {
			if strings.Contains(m, c.tag) {
				found = true
				break
			}
		}
		if !found {
			t.Errorf("metric %q missing tag %q; matching packets: %v", c.metric, c.tag, matches)
		}
	}
}
