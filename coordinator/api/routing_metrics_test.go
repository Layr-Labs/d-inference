package api

import (
	"context"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/datadog"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/ratelimit"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
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
	var out []string
	deadline := time.NewTimer(time.Second)
	defer deadline.Stop()
	var quiet *time.Timer
	var quietC <-chan time.Time
	defer func() {
		if quiet != nil {
			quiet.Stop()
		}
	}()
	for {
		select {
		case packet := <-c.packets:
			out = append(out, packet)
			if quiet == nil {
				quiet = time.NewTimer(20 * time.Millisecond)
			} else {
				if !quiet.Stop() {
					select {
					case <-quiet.C:
					default:
					}
				}
				quiet.Reset(20 * time.Millisecond)
			}
			quietC = quiet.C
		case <-quietC:
			return out
		case <-deadline.C:
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
		Backend:                 "mlx-swift",
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

func TestRoutingMetrics_SelectedTraversesDispatch(t *testing.T) {
	collector := newUDPCollector(t)
	defer collector.Close()

	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	ddClient := newTestDD(t, collector)
	defer ddClient.Close()
	srv.SetDatadog(ddClient)
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	const model = "routing-metrics-selected"
	provider := startFailoverProvider(t, ctx, ts, reg, failoverProviderConfig{
		Name: "routing-metrics-provider", Version: "0.8.0", DecodeTPS: 120,
		Models: []failoverModelSpec{{ID: model}},
		Script: func(ctx context.Context, fp *failoverProvider, req protocol.InferenceRequestMessage, _ []byte) {
			fp.serveFull(ctx, req, model, "metrics-ok")
		},
	})

	status, body, err := postSSE(ctx, ts.URL, "/v1/completions", "test-key",
		`{"model":"`+model+`","prompt":"hello","stream":true}`)
	if err != nil {
		t.Fatal(err)
	}
	if status != http.StatusOK || !strings.Contains(body, "metrics-ok") {
		t.Fatalf("completion status=%d body=%s, want served 200", status, body)
	}

	_ = ddClient.Statsd.Flush()
	packets := collector.drain()
	checks := []struct {
		metric string
		tag    string
	}{
		{"routing.decisions", "outcome:selected"},
		{"routing.decisions", "model:" + model},
		{"routing.provider_selected", "provider_id:" + provider.registryID},
		{"routing.provider_selected", "model:" + model},
		{"routing.cost_ms", "provider_id:" + provider.registryID},
	}
	for _, check := range checks {
		matches := findMetrics(packets, check.metric)
		if !hasMetric(matches, check.tag) {
			t.Errorf("production metric %q missing tag %q; matching packets: %v",
				check.metric, check.tag, matches)
		}
	}
}

func TestRoutingMetrics_ModelTooLargeTraversesAdmission(t *testing.T) {
	collector := newUDPCollector(t)
	defer collector.Close()

	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	const model = "routing-metrics-too-large"
	reg.SetModelCatalog([]registry.CatalogEntry{{ID: model, SizeGB: 128}})
	p := makeRoutableProvider(t, reg, "tiny-provider", model)
	p.Mu().Lock()
	p.BackendCapacity.Slots[0].State = "idle_shutdown"
	p.Mu().Unlock()

	srv := NewServer(reg, st, ServerConfig{}, logger)
	ddClient := newTestDD(t, collector)
	defer ddClient.Close()
	srv.SetDatadog(ddClient)

	req := httptest.NewRequest(http.MethodPost, "/v1/completions",
		strings.NewReader(`{"model":"`+model+`","prompt":"hello"}`))
	req.Header.Set("Authorization", "Bearer test-key")
	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("status=%d, want 503 for permanently oversized model; body=%s",
			rec.Code, rec.Body.String())
	}

	_ = ddClient.Statsd.Flush()
	packets := collector.drain()
	matches := findMetrics(packets, "routing.decisions")
	if !hasMetric(matches, "outcome:model_too_large") ||
		!hasMetric(matches, "model:"+model) {
		t.Fatalf("model-too-large admission metric missing exact outcome/model tags: %v", matches)
	}
}

func TestRateLimitMetrics_ConsumerRejectionEmitsCounter(t *testing.T) {
	collector := newUDPCollector(t)
	defer collector.Close()

	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)

	srv := NewServer(reg, st, ServerConfig{}, logger)
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
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)

	srv := NewServer(reg, st, ServerConfig{}, logger)
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

func TestAttestationFailureMetricTraversesChallengeHandler(t *testing.T) {
	collector := newUDPCollector(t)
	defer collector.Close()

	logger := slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelError}))
	st := store.NewMemory(store.Config{AdminKey: "test-key"})
	reg := registry.New(logger)
	srv := NewServer(reg, st, ServerConfig{}, logger)
	ddClient := newTestDD(t, collector)
	defer ddClient.Close()
	srv.SetDatadog(ddClient)

	provider := makeRoutableProvider(t, reg, "attestation-metric-provider", "m")
	if failures := srv.handleChallengeFailure(provider.ID, "signature invalid"); failures != 1 {
		t.Fatalf("challenge failure count = %d, want 1", failures)
	}

	_ = ddClient.Statsd.Flush()
	matches := findMetrics(collector.drain(), "attestation.challenges")
	if !hasMetric(matches, "outcome:failed") {
		t.Fatalf("challenge handler did not emit failed outcome: %v", matches)
	}
}
