package api

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// cachePlanFixture is the production shape of a coordinator whose prompt
// sidecar is enabled while the cache-routing gate is off: a real artifact
// provisioner (artifact served by an in-process origin and verified to ready),
// a real sidecar client, and a real preload controller whose supervisor never
// started a child, so ReadyFor is honestly false. Shared by the regression test
// and the benchmark.
type cachePlanFixture struct {
	server *Server
	model  string
	body   []byte
}

func newCachePlanFixture(tb testing.TB) *cachePlanFixture {
	tb.Helper()
	const (
		modelID  = "fixture-model"
		r2Prefix = "models/fixture"
		filePath = "tokenizer.json"
	)
	artifact := []byte(`{"version":"1.0"}`)
	digest := sha256.Sum256(artifact)
	aggregate := sha256.Sum256(digest[:])

	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/"+r2Prefix+"/"+filePath {
			http.NotFound(w, r)
			return
		}
		_, _ = w.Write(artifact)
	}))
	tb.Cleanup(origin.Close)
	baseURL, err := url.Parse(origin.URL + "/")
	if err != nil {
		tb.Fatal(err)
	}
	root, err := filepath.EvalSymlinks(tb.TempDir())
	if err != nil {
		tb.Fatal(err)
	}
	tb.Cleanup(func() {
		_ = filepath.Walk(root, func(path string, _ os.FileInfo, _ error) error {
			return os.Chmod(path, 0o700)
		})
	})
	cache, err := promptcontract.NewArtifactCache(promptcontract.ArtifactCacheConfig{
		Root: root, BaseURL: baseURL, HTTPClient: origin.Client(), AllowHTTP: true,
	})
	if err != nil {
		tb.Fatal(err)
	}
	provisioner, err := promptcontract.NewProvisioner(context.Background(), cache,
		promptcontract.ProvisionerConfig{MaxConcurrent: 1, MaxModels: 1})
	if err != nil {
		tb.Fatal(err)
	}
	tb.Cleanup(provisioner.Close)

	// The socket is never dialed: the supervisor is never started, which is
	// exactly what makes the preload gate false.
	socket := filepath.Join(tb.TempDir(), "sidecar.sock")
	client := promptcontract.NewClient(promptcontract.ClientConfig{SocketPath: socket})
	tb.Cleanup(client.Close)
	supervisor := promptcontract.NewSupervisor(promptcontract.SupervisorConfig{SocketPath: socket})
	preloader, err := promptcontract.NewPreloadController(
		provisioner, supervisor, promptcontract.PreloadControllerConfig{})
	if err != nil {
		tb.Fatal(err)
	}

	server := &Server{
		logger:          quietLogger(),
		metrics:         NewMetrics(),
		registry:        registry.New(quietLogger()),
		promptArtifacts: provisioner,
		promptContract:  client,
		promptPreloader: preloader,
	}
	if err := server.reconcilePromptArtifacts([]store.ModelRegistryRecord{{
		ModelRegistryEntry: store.ModelRegistryEntry{ID: modelID},
		ActiveVersion: &store.ModelVersion{
			R2Prefix:        r2Prefix,
			AggregateSHA256: hex.EncodeToString(aggregate[:]),
		},
		Files: []store.ModelVersionFile{{
			Path: filePath, SizeBytes: int64(len(artifact)),
			SHA256: hex.EncodeToString(digest[:]), Role: "tokenizer",
		}},
	}}); err != nil {
		tb.Fatal(err)
	}
	deadline := time.Now().Add(10 * time.Second)
	for {
		status, ok := provisioner.Status(modelID)
		if ok && status.ArtifactReady && status.PromptContractID != "" {
			break
		}
		if time.Now().After(deadline) {
			tb.Fatalf("prompt artifact never became ready: %+v", status)
		}
		time.Sleep(10 * time.Millisecond)
	}
	return &cachePlanFixture{
		server: server,
		model:  modelID,
		body:   []byte(`{"messages":[{"role":"user","content":"hello"}]}`),
	}
}

func (f *cachePlanFixture) plan() registry.CachePlan {
	return f.server.planCacheRoute(context.Background(), "account", f.model, f.body, false)
}

func (f *cachePlanFixture) offCount() int64 {
	return f.server.metrics.Snapshot().Counters["exact_cache_plan_total{outcome=off}"]
}

func configureCacheRoutingMode(tb testing.TB, reg *registry.Registry, mode string) {
	tb.Helper()
	if err := reg.ConfigureCacheRouting(registry.CacheRoutingConfig{
		Mode: mode, ActivationPct: 100, TTL: time.Minute, MaxHolders: 4,
		MaxDiscountMs: 1000, MaxCostFraction: .35,
		MasterKey: base64.RawURLEncoding.EncodeToString(
			[]byte("0123456789abcdef0123456789abcdef")),
	}); err != nil {
		tb.Fatal(err)
	}
}

// TestPlanCacheRouteOffSkipsSidecarGate pins that while cache routing is off
// the per-request plan returns before the artifact status read, the preload
// gate (provisioner snapshot + supervisor status), and the registry lock, yet
// still records exact_cache_plan_total{outcome=off} once per request. Fails
// before the change on the counter: the gate ran first, the preloader was not
// ready, and nothing was recorded. The mode=on half is the pre-existing path
// and must be unchanged: the gate runs, the preloader is honestly not ready,
// and no outcome is recorded.
func TestPlanCacheRouteOffSkipsSidecarGate(t *testing.T) {
	f := newCachePlanFixture(t)
	const rounds = 5
	for i := 0; i < rounds; i++ {
		if plan := f.plan(); plan.CacheScope != "" || len(plan.Boundaries) != 0 {
			t.Fatalf("mode=off produced a plan: %+v", plan)
		}
	}
	if got := f.offCount(); got != rounds {
		t.Fatalf("exact_cache_plan_total{outcome=off} = %d after %d mode=off plans, want %d",
			got, rounds, rounds)
	}

	// Ceiling: a mode=off plan costs exactly the counter emission and nothing
	// from the provisioner, preloader, or registry.
	emitOnly := testing.AllocsPerRun(200, func() {
		f.server.emitExactCachePlan(registry.CachePlanResult{Outcome: registry.CachePlanOff})
	})
	if planAllocs := testing.AllocsPerRun(200, func() { f.plan() }); planAllocs > emitOnly {
		t.Fatalf("mode=off plan allocated %v/op, want at most the emission's %v/op",
			planAllocs, emitOnly)
	}

	before := f.offCount()
	configureCacheRoutingMode(t, f.server.registry, registry.CacheRoutingOn)
	if plan := f.plan(); plan.CacheScope != "" || len(plan.Boundaries) != 0 {
		t.Fatalf("unready preloader produced a plan: %+v", plan)
	}
	if got := f.offCount(); got != before {
		t.Fatalf("mode=on recorded an off outcome: %d -> %d", before, got)
	}
	// ConfigureCacheRouting must re-arm the early-out on every transition.
	configureCacheRoutingMode(t, f.server.registry, registry.CacheRoutingOff)
	f.plan()
	if got := f.offCount(); got != before+1 {
		t.Fatalf("mode=off after mode=on did not resume the off outcome: %d -> %d", before, got)
	}
	// A rejected configuration leaves the gate where it was.
	if err := f.server.registry.ConfigureCacheRouting(registry.CacheRoutingConfig{
		Mode: "shadow", ActivationPct: 100, MaxHolders: 4,
	}); err == nil {
		t.Fatal("invalid mode was accepted")
	}
	f.plan()
	if got := f.offCount(); got != before+2 {
		t.Fatalf("rejected configuration changed the gate: %d -> %d", before, got)
	}
}

// BenchmarkPlanCacheRouteOff measures the per-request cost of the plan step
// with the sidecar wired and cache routing off (the production configuration).
func BenchmarkPlanCacheRouteOff(b *testing.B) {
	f := newCachePlanFixture(b)
	ctx := context.Background()
	b.ReportAllocs()
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		_ = f.server.planCacheRoute(ctx, "account", f.model, f.body, false)
	}
}
