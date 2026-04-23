package api

import (
	"context"
	"fmt"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/coordinator/internal/datadog"
	"github.com/eigeninference/coordinator/internal/protocol"
	"github.com/eigeninference/coordinator/internal/ratelimit"
	"github.com/eigeninference/coordinator/internal/registry"
	"github.com/eigeninference/coordinator/internal/store"
)

// udpCollector listens on a random UDP port and collects DogStatsD packets.
type udpCollector struct {
	conn    *net.UDPConn
	packets chan string
	done    chan struct{}
}

func newUDPCollector(t *testing.T) *udpCollector {
	t.Helper()
	addr, err := net.ResolveUDPAddr("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	conn, err := net.ListenUDP("udp", addr)
	if err != nil {
		t.Fatal(err)
	}
	c := &udpCollector{
		conn:    conn,
		packets: make(chan string, 256),
		done:    make(chan struct{}),
	}
	go func() {
		defer close(c.done)
		buf := make([]byte, 8192)
		for {
			n, _, err := conn.ReadFromUDP(buf)
			if err != nil {
				return
			}
			for _, line := range strings.Split(string(buf[:n]), "\n") {
				line = strings.TrimSpace(line)
				if line != "" {
					c.packets <- line
				}
			}
		}
	}()
	return c
}

func (c *udpCollector) Addr() string {
	return c.conn.LocalAddr().String()
}

func (c *udpCollector) Close() {
	c.conn.Close()
	<-c.done
}

func (c *udpCollector) drain() []string {
	time.Sleep(200 * time.Millisecond)
	var out []string
	for {
		select {
		case p := <-c.packets:
			out = append(out, p)
		default:
			return out
		}
	}
}

func hasMetric(packets []string, substr string) bool {
	for _, p := range packets {
		if strings.Contains(p, substr) {
			return true
		}
	}
	return false
}

func findMetrics(packets []string, substr string) []string {
	var out []string
	for _, p := range packets {
		if strings.Contains(p, substr) {
			out = append(out, p)
		}
	}
	return out
}

func newTestDD(t *testing.T, collector *udpCollector) *datadog.Client {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	// Use datadog.NewClient with a config pointing at our collector so all
	// internal fields (logTicker, logDone, etc.) are properly initialized.
	cfg := datadog.Config{
		StatsdAddr: collector.Addr(),
		FlushSecs:  60,
	}
	client, err := datadog.NewClient(cfg, logger)
	if err != nil {
		t.Fatal(err)
	}
	return client
}

func makeRoutableProvider(t *testing.T, reg *registry.Registry, id, model string) *registry.Provider {
	t.Helper()
	msg := &protocol.RegisterMessage{
		Type: protocol.TypeRegister,
		Hardware: protocol.Hardware{
			MachineModel:       "Mac15,8",
			ChipName:           "Apple M3 Max",
			MemoryGB:           64,
			MemoryBandwidthGBs: 400,
			CPUCores:           protocol.CPUCores{Total: 16, Performance: 12, Efficiency: 4},
			GPUCores:           40,
		},
		Models: []protocol.ModelInfo{
			{ID: model, SizeBytes: 5_000_000_000, ModelType: "chat", Quantization: "4bit"},
		},
		Backend:                 "inprocess-mlx",
		PublicKey:               "fX6XYH7p2hmM3ogeXaAsY+p8M6UKD1df/LJUN9Nj9Nw=",
		EncryptedResponseChunks: true,
		PrivacyCapabilities: &protocol.PrivacyCapabilities{
			TextBackendInprocess:    true,
			TextProxyDisabled:       true,
			PythonRuntimeLocked:     true,
			DangerousModulesBlocked: true,
			SIPEnabled:              true,
			AntiDebugEnabled:        true,
			CoreDumpsDisabled:       true,
			EnvScrubbed:             true,
		},
	}
	p := reg.Register(id, nil, msg)
	p.Mu().Lock()
	p.TrustLevel = registry.TrustHardware
	p.RuntimeVerified = true
	p.RuntimeManifestChecked = true
	p.ChallengeVerifiedSIP = true
	p.LastChallengeVerified = time.Now()
	p.DecodeTPS = 90.0
	p.PrefillTPS = 500.0
	p.SystemMetrics = protocol.SystemMetrics{
		MemoryPressure: 0.1,
		CPUUsage:       0.1,
		ThermalState:   "nominal",
	}
	p.BackendCapacity = &protocol.BackendCapacity{
		TotalMemoryGB:     64,
		GPUMemoryActiveGB: 8,
		Slots: []protocol.BackendSlotCapacity{
			{Model: model, State: "running", NumRunning: 0, NumWaiting: 0},
		},
	}
	p.Mu().Unlock()
	return p
}

func TestRoutingMetrics_SelectedEmitsDecisionAndCost(t *testing.T) {
	collector := newUDPCollector(t)
	defer collector.Close()

	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)

	model := "test-routing-model"
	makeRoutableProvider(t, reg, "p1", model)

	pr := &registry.PendingRequest{
		RequestID:             "req-test-1",
		Model:                 model,
		EstimatedPromptTokens: 100,
		RequestedMaxTokens:    256,
		ChunkCh:               make(chan string, 1),
		CompleteCh:            make(chan protocol.UsageInfo, 1),
		ErrorCh:               make(chan protocol.InferenceErrorMessage, 1),
	}

	srv := NewServer(reg, st, logger)
	ddClient := newTestDD(t, collector)
	defer ddClient.Close()
	srv.SetDatadog(ddClient)

	provider, decision := reg.ReserveProviderEx(model, pr)
	if provider == nil {
		t.Fatal("ReserveProviderEx returned nil — provider not routable")
	}

	srv.ddIncr("routing.decisions", []string{"model:" + model, "outcome:selected"})
	srv.ddIncr("routing.provider_selected", []string{"provider_id:" + provider.ID, "model:" + model})
	srv.ddHistogram("routing.cost_ms", decision.CostMs, []string{"model:" + model})
	if decision.EffectiveTPS > 0 {
		srv.ddGauge("routing.effective_decode_tps", decision.EffectiveTPS, []string{"provider_id:" + provider.ID})
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
	st := store.NewMemory("test-key")
	reg := registry.New(logger)

	srv := NewServer(reg, st, logger)
	ddClient := newTestDD(t, collector)
	defer ddClient.Close()
	srv.SetDatadog(ddClient)

	model := "nonexistent-model"
	pr := &registry.PendingRequest{
		RequestID:          "req-noprovider",
		Model:              model,
		RequestedMaxTokens: 256,
		ChunkCh:            make(chan string, 1),
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
	srv.ddIncr("routing.decisions", []string{"model:" + model, "outcome:" + outcome})

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
	st := store.NewMemory("test-key")
	reg := registry.New(logger)

	model := "big-model"
	reg.SetModelCatalog([]registry.CatalogEntry{{ID: model, SizeGB: 128}})
	p := makeRoutableProvider(t, reg, "tiny-provider", model)
	// Force idle_shutdown so the gate checks full model weight fit, not just KV.
	p.Mu().Lock()
	p.BackendCapacity.Slots[0].State = "idle_shutdown"
	p.Mu().Unlock()

	srv := NewServer(reg, st, logger)
	ddClient := newTestDD(t, collector)
	defer ddClient.Close()
	srv.SetDatadog(ddClient)

	pr := &registry.PendingRequest{
		RequestID:          "req-overcap",
		Model:              model,
		RequestedMaxTokens: 256,
		ChunkCh:            make(chan string, 1),
		CompleteCh:         make(chan protocol.UsageInfo, 1),
		ErrorCh:            make(chan protocol.InferenceErrorMessage, 1),
	}

	provider, decision := reg.ReserveProviderEx(model, pr)
	if provider != nil {
		t.Fatal("expected nil — 64GB provider can't fit 128GB model")
	}

	outcome := "no_provider"
	if decision.CapacityRejections > 0 && decision.CandidateCount == 0 {
		outcome = "over_capacity"
	}
	srv.ddIncr("routing.decisions", []string{"model:" + model, "outcome:" + outcome})

	_ = ddClient.Statsd.Flush()
	packets := collector.drain()

	if !hasMetric(packets, "outcome:over_capacity") {
		t.Errorf("expected over_capacity outcome when provider too small; got packets: %v", packets)
	}
}

func TestRateLimitMetrics_ConsumerRejectionEmitsCounter(t *testing.T) {
	collector := newUDPCollector(t)
	defer collector.Close()

	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)

	srv := NewServer(reg, st, logger)
	ddClient := newTestDD(t, collector)
	defer ddClient.Close()
	srv.SetDatadog(ddClient)
	srv.SetRateLimiter(ratelimit.New(ratelimit.Config{RPS: 0.001, Burst: 1}))

	handler := srv.rateLimitConsumer(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})

	ctx := context.WithValue(context.Background(), ctxKeyConsumer, "acct-ratelimit-test")

	rec := httptest.NewRecorder()
	handler(rec, httptest.NewRequest("POST", "/test", nil).WithContext(ctx))
	if rec.Code != http.StatusOK {
		t.Fatalf("first request got %d, want 200", rec.Code)
	}

	rec = httptest.NewRecorder()
	handler(rec, httptest.NewRequest("POST", "/test", nil).WithContext(ctx))
	if rec.Code != http.StatusTooManyRequests {
		t.Fatalf("second request got %d, want 429", rec.Code)
	}

	_ = ddClient.Statsd.Flush()
	packets := collector.drain()

	if !hasMetric(packets, "ratelimit.rejections") {
		t.Errorf("missing ratelimit.rejections metric; got packets: %v", packets)
	}
	if !hasMetric(packets, "tier:consumer") {
		t.Errorf("missing tier:consumer tag; got packets: %v", packets)
	}
}

func TestRateLimitMetrics_FinancialTierTag(t *testing.T) {
	collector := newUDPCollector(t)
	defer collector.Close()

	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)

	srv := NewServer(reg, st, logger)
	ddClient := newTestDD(t, collector)
	defer ddClient.Close()
	srv.SetDatadog(ddClient)
	srv.SetFinancialRateLimiter(ratelimit.New(ratelimit.Config{RPS: 0.001, Burst: 1}))

	handler := srv.rateLimitFinancial(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})

	ctx := context.WithValue(context.Background(), ctxKeyConsumer, "acct-fin-test")

	rec := httptest.NewRecorder()
	handler(rec, httptest.NewRequest("POST", "/test", nil).WithContext(ctx))
	rec = httptest.NewRecorder()
	handler(rec, httptest.NewRequest("POST", "/test", nil).WithContext(ctx))
	if rec.Code != http.StatusTooManyRequests {
		t.Fatalf("got %d, want 429", rec.Code)
	}

	_ = ddClient.Statsd.Flush()
	packets := collector.drain()

	if !hasMetric(packets, "tier:financial") {
		t.Errorf("missing tier:financial tag; got packets: %v", packets)
	}
}

func TestAttestationMetrics_AllOutcomes(t *testing.T) {
	collector := newUDPCollector(t)
	defer collector.Close()

	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)

	srv := NewServer(reg, st, logger)
	ddClient := newTestDD(t, collector)
	defer ddClient.Close()
	srv.SetDatadog(ddClient)

	for _, outcome := range []string{"sent", "passed", "failed", "status_sig_missing"} {
		srv.ddIncr("attestation.challenges", []string{"outcome:" + outcome})
	}

	_ = ddClient.Statsd.Flush()
	packets := collector.drain()

	for _, outcome := range []string{"sent", "passed", "failed", "status_sig_missing"} {
		if !hasMetric(packets, "outcome:"+outcome) {
			t.Errorf("missing attestation.challenges{outcome:%s}; got packets: %v", outcome, packets)
		}
	}
}

func TestInferenceMetrics_CompletionCounters(t *testing.T) {
	collector := newUDPCollector(t)
	defer collector.Close()

	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)

	srv := NewServer(reg, st, logger)
	ddClient := newTestDD(t, collector)
	defer ddClient.Close()
	srv.SetDatadog(ddClient)

	model := "test-completion-model"
	srv.ddIncr("inference.completions", []string{"model:" + model})
	srv.ddHistogram("inference.completion_tokens", 42, []string{"model:" + model})

	_ = ddClient.Statsd.Flush()
	packets := collector.drain()

	if !hasMetric(packets, "inference.completions") {
		t.Errorf("missing inference.completions; got packets: %v", packets)
	}
	if !hasMetric(packets, "inference.completion_tokens") {
		t.Errorf("missing inference.completion_tokens; got packets: %v", packets)
	}
	if !hasMetric(packets, "model:"+model) {
		t.Errorf("missing model tag; got packets: %v", packets)
	}
}

func TestDDMetrics_NilClientNoOps(t *testing.T) {
	srv := &Server{}
	// Must not panic when dd is nil.
	srv.ddIncr("test.counter", []string{"a:b"})
	srv.ddHistogram("test.histogram", 1.0, []string{"a:b"})
	srv.ddGauge("test.gauge", 1.0, []string{"a:b"})
}

func TestRoutingMetrics_AllTagsOnSelection(t *testing.T) {
	collector := newUDPCollector(t)
	defer collector.Close()

	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory("test-key")
	reg := registry.New(logger)

	model := "tag-check-model"
	p := makeRoutableProvider(t, reg, "tag-provider", model)

	srv := NewServer(reg, st, logger)
	ddClient := newTestDD(t, collector)
	defer ddClient.Close()
	srv.SetDatadog(ddClient)

	pr := &registry.PendingRequest{
		RequestID:             fmt.Sprintf("req-tags-%d", time.Now().UnixNano()),
		Model:                 model,
		EstimatedPromptTokens: 50,
		RequestedMaxTokens:    128,
		ChunkCh:               make(chan string, 1),
		CompleteCh:            make(chan protocol.UsageInfo, 1),
		ErrorCh:               make(chan protocol.InferenceErrorMessage, 1),
	}

	provider, decision := reg.ReserveProviderEx(model, pr)
	if provider == nil {
		t.Fatal("routing returned nil")
	}

	srv.ddIncr("routing.decisions", []string{"model:" + model, "outcome:selected"})
	srv.ddIncr("routing.provider_selected", []string{"provider_id:" + provider.ID, "model:" + model})
	srv.ddHistogram("routing.cost_ms", decision.CostMs, []string{"model:" + model})
	srv.ddGauge("routing.effective_decode_tps", decision.EffectiveTPS, []string{"provider_id:" + provider.ID})

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
