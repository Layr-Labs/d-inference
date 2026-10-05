package inference_test

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"os/signal"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/api/observation"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/routeplan"
	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

// A model revised under its own ID gets a new aggregate hash and, when its
// prompt files change as they do here, a new prompt contract. Planning must
// follow the revision through the preload controller's active set and the
// registry's allowlist projection without taking the other catalog model with
// it: the other model plans in every state, and the revised one plans again,
// under its new contract, only once the allowlist names it.
//
// Every catalog sync republishes all identities as pending, and a changed
// verified set is acknowledged again only by a fresh preload, so each planned
// expectation first waits for the tokenizer acknowledgement it depends on.
func TestCachePlanningFollowsSameIDModelRevision(t *testing.T) {
	f := newModelRevisionFixture(t)
	const revisedModel = "revised-model"
	previous := f.publish(t, revisedModel, "v1", `{"version":"1.0"}`, nil)
	other := f.publish(t, "steady-model", "v1", `{"version":"1.0","steady":true}`, nil)
	configureStaleAllowlistTest(t, f.srv, registry.CacheRoutingOn, []registry.CacheRoutingArtifact{previous, other})
	t.Run("listed models plan", func(t *testing.T) {
		f.expectPlanned(t, previous)
		f.expectPlanned(t, other)
	})

	downloaded := make(chan struct{})
	live := f.publish(t, revisedModel, "v2", `{"version":"2.0"}`, downloaded)
	if live.ModelAggregateSHA256 == previous.ModelAggregateSHA256 || live.PromptContractID == previous.PromptContractID {
		t.Fatalf("revision kept an identity of the artifact it replaced: %+v -> %+v", previous, live)
	}
	t.Run("pending revision leaves the other model planned", func(t *testing.T) {
		f.expectPlanned(t, other)
		f.expectNotPlanned(t, revisedModel, routeplan.CachePlanningArtifactPending)
	})

	close(downloaded)
	t.Run("ready revision outside the allowlist is stale and unplanned", func(t *testing.T) {
		// Verified and loaded, so only the allowlist still excludes it.
		if !f.waitAcknowledged(live) {
			t.Fatalf("revision tokenizer was not loaded: preload=%+v artifacts=%+v",
				f.controller.Status(), f.srv.ExactCacheStatusSnapshot().PromptArtifacts)
		}
		f.expectStaleModels(t, 1)
		f.expectNotPlanned(t, revisedModel, routeplan.CachePlanningIneligible)
		f.expectPlanned(t, other)
	})

	configureStaleAllowlistTest(t, f.srv, registry.CacheRoutingOn, []registry.CacheRoutingArtifact{previous, other, live})
	t.Run("appended tuple plans the revision under its new contract", func(t *testing.T) {
		f.expectStaleModels(t, 0)
		f.expectPlanned(t, live)
		f.expectPlanned(t, other)
	})
}

// modelRevisionFixture runs cache planning for a catalog of several models: a
// composed server over a real model store, the real artifact provisioner,
// sidecar supervisor and preload controller, and a supervised sidecar stand-in.
// The shared planning fixture provisions one model and loads one contract, so
// it cannot hold a revised model beside an unchanged one.
type modelRevisionFixture struct {
	srv        *serverFixture
	models     *memory.MemoryStore
	controller *promptcontract.PreloadController
	sidecar    *http.Client // Reaches the stand-in's own record of plan calls.

	originMu sync.Mutex
	origin   map[string]originTokenizer // By download path.
}

type originTokenizer struct {
	payload []byte
	held    <-chan struct{} // Nil serves at once; otherwise the download waits for close.
}

func newModelRevisionFixture(t *testing.T) *modelRevisionFixture {
	t.Helper()
	models := memory.NewMemory(store.Config{})
	f := &modelRevisionFixture{
		srv:    newComposedServer(registry.New(quietLogger()), models, TestServerConfig{}, quietLogger()),
		models: models, origin: make(map[string]originTokenizer),
	}
	t.Cleanup(f.srv.Close)
	shortParent, err := filepath.EvalSymlinks("/tmp") // A Unix socket path must stay short.
	if err != nil {
		t.Fatal(err)
	}
	root, err := os.MkdirTemp(shortParent, "cache-revision-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		// Verified artifacts are published read-only.
		_ = filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
			if err != nil || info.Mode()&os.ModeSymlink != 0 {
				return err
			}
			return os.Chmod(path, 0o700)
		})
		if err := os.RemoveAll(root); err != nil {
			t.Errorf("remove model revision fixture: %v", err)
		}
	})
	origin := httptest.NewServer(http.HandlerFunc(f.serveTokenizer))
	t.Cleanup(origin.Close)
	originURL, err := url.Parse(origin.URL + "/")
	if err != nil {
		t.Fatal(err)
	}
	artifactRoot := filepath.Join(root, "artifacts")
	cache, err := promptcontract.NewArtifactCache(promptcontract.ArtifactCacheConfig{
		Root: artifactRoot, BaseURL: originURL, HTTPClient: origin.Client(), AllowHTTP: true,
	})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	// The default two workers: a held download occupies one while the other
	// re-verifies the rest of the catalog.
	provisioner, err := promptcontract.NewProvisioner(ctx, cache, promptcontract.ProvisionerConfig{})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(provisioner.Close)

	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	launcher, socket := filepath.Join(root, "sidecar"), filepath.Join(root, "s.sock")
	script := "#!/bin/sh\n" + modelRevisionSidecarEnv + "=1 exec '" + strings.ReplaceAll(executable, "'", `'"'"'`) +
		"' -test.run='^TestModelRevisionSidecarProcess$' -test.timeout=2m -- \"$@\"\n"
	if err := os.WriteFile(launcher, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	supervisor := promptcontract.NewSupervisor(promptcontract.SupervisorConfig{
		Enabled: true, BinaryPath: launcher, SocketPath: socket, ArtifactRoot: artifactRoot,
		RequestTimeout: 2 * time.Second, HealthTimeout: time.Second, PreloadTimeout: 5 * time.Second,
		StartupTimeout: 15 * time.Second, HealthInterval: 20 * time.Millisecond, ShutdownTimeout: time.Second,
	})
	t.Cleanup(supervisor.Close)
	f.controller, err = promptcontract.NewPreloadController(provisioner, supervisor, promptcontract.PreloadControllerConfig{
		PollInterval: 10 * time.Millisecond, MetricsInterval: time.Hour,
		FailureBackoffMin: 10 * time.Millisecond, FailureBackoffMax: 100 * time.Millisecond,
	})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(f.controller.Close)

	// Application startup order: provisioner, first catalog sync, sidecar, then
	// the controller with its registry projection installed before it starts.
	f.srv.SetPromptArtifactProvisioner(provisioner)
	f.srv.server.SyncModelCatalog()
	f.srv.SetPromptSupervisor(supervisor)
	f.srv.SetPromptContractClient(supervisor.Client())
	supervisor.Start(ctx)
	f.srv.SetPromptPreloadController(f.controller)
	f.controller.Start(ctx)

	transport := &http.Transport{DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, "unix", socket)
	}}
	t.Cleanup(transport.CloseIdleConnections)
	f.sidecar = &http.Client{Transport: transport, Timeout: 2 * time.Second}
	return f
}

func (f *modelRevisionFixture) serveTokenizer(w http.ResponseWriter, r *http.Request) {
	f.originMu.Lock()
	tokenizer, published := f.origin[r.URL.Path]
	f.originMu.Unlock()
	if !published {
		http.NotFound(w, r)
		return
	}
	if tokenizer.held != nil {
		select {
		case <-tokenizer.held:
		case <-r.Context().Done(): // Provisioner shutdown abandons a download that is still held.
			return
		}
	}
	_, _ = w.Write(tokenizer.payload)
}

// publish promotes a model version whose only prompt file is the tokenizer and
// syncs the catalog, as publishing a revision does. It returns the artifact the
// catalog now names for the model. A non-nil held keeps the origin from serving
// the tokenizer until it is closed, which leaves the artifact pending.
func (f *modelRevisionFixture) publish(t *testing.T, model, version, tokenizer string, held <-chan struct{}) registry.CacheRoutingArtifact {
	t.Helper()
	digest := sha256.Sum256([]byte(tokenizer))
	aggregate := sha256.Sum256(digest[:])
	prefix := model + "/" + version
	f.originMu.Lock()
	f.origin["/"+prefix+"/tokenizer.json"] = originTokenizer{payload: []byte(tokenizer), held: held}
	f.originMu.Unlock()
	err := f.models.SetModelVersion(
		&store.ModelRegistryEntry{ID: model, Status: "active"},
		&store.ModelVersion{
			ModelID: model, Version: version, R2Prefix: prefix, AggregateSHA256: hex.EncodeToString(aggregate[:]),
			TotalSizeBytes: int64(len(tokenizer)), FileCount: 1, Status: "ready",
		},
		[]store.ModelVersionFile{{
			Path: "tokenizer.json", Role: "tokenizer", SizeBytes: int64(len(tokenizer)), SHA256: hex.EncodeToString(digest[:]),
		}})
	if err == nil {
		err = f.models.PromoteModelVersion(model, version)
	}
	if err != nil {
		t.Fatal(err)
	}
	f.srv.server.SyncModelCatalog()
	status, listed := f.srv.PromptArtifactStatus(model)
	if !listed {
		t.Fatalf("catalog sync did not publish %s", model)
	}
	return registry.CacheRoutingArtifact{
		ModelID: status.ModelID, ModelAggregateSHA256: status.ModelAggregateSHA256, PromptContractID: status.PromptContractID,
	}
}

func (f *modelRevisionFixture) plan(model string) registry.CachePlanResult {
	return f.srv.NewCachePlanner().PlanResult(context.Background(), routeplan.CachePlanningInput{
		Account: "planning-account", Model: model,
		Body: []byte(`{"messages":[{"role":"user","content":"synthetic planning fixture"}]}`),
	})
}

// waitAcknowledged waits for the running sidecar to have loaded the artifact's
// tokenizer for the current catalog, which a planned request requires, and
// reports whether it did.
func (f *modelRevisionFixture) waitAcknowledged(artifact registry.CacheRoutingArtifact) bool {
	return waitForCond(10*time.Second, func() bool { return f.controller.ReadyFor(artifact.PromptContractID) })
}

// expectPlanned requires one request for the artifact's model to be planned
// through exactly one sidecar call, made under the artifact's prompt contract.
func (f *modelRevisionFixture) expectPlanned(t *testing.T, artifact registry.CacheRoutingArtifact) {
	t.Helper()
	acknowledged := f.waitAcknowledged(artifact)
	before := f.sidecarState(t)
	result := f.plan(artifact.ModelID)
	after := f.sidecarState(t)
	if !acknowledged || result.Outcome != registry.CachePlanPlanned || result.Plan.CacheScope == "" ||
		after.Plans != before.Plans+1 || after.LastContract != artifact.PromptContractID {
		t.Errorf("%s was not planned under its live contract: tokenizer acknowledged=%t outcome=%q scoped=%t sidecar plans %d -> %d, last under live contract=%t",
			artifact.ModelID, acknowledged, result.Outcome, result.Plan.CacheScope != "", before.Plans, after.Plans,
			after.LastContract == artifact.PromptContractID)
	}
}

// expectNotPlanned requires one request for the model to be decided for exactly
// the given reason, without a plan and without a sidecar call.
func (f *modelRevisionFixture) expectNotPlanned(t *testing.T, model string, reason routeplan.CachePlanningDecisionReason) {
	t.Helper()
	decisionsBefore, before := f.srv.observation.Metrics().Snapshot(), f.sidecarState(t)
	result := f.plan(model)
	decided := cachePlanningDecisionReasons(decisionsBefore, f.srv.observation.Metrics().Snapshot(), model)
	after := f.sidecarState(t)
	if result.Plan.CacheScope != "" || result.SidecarCalled || after.Plans != before.Plans ||
		!slices.Equal(decided, []string{string(reason)}) {
		t.Errorf("%s: decided %v, want [%s]; outcome=%q scoped=%t sidecar called=%t plans %d -> %d",
			model, decided, reason, result.Outcome, result.Plan.CacheScope != "", result.SidecarCalled,
			before.Plans, after.Plans)
	}
}

// cachePlanningDecisionReasons lists the reasons cache planning recorded for
// the model between two metric snapshots.
func cachePlanningDecisionReasons(before, after observation.MetricsSnapshot, model string) []string {
	prefix := "cache_model_planning_decision_total{model=" + model + ",reason="
	var reasons []string
	for name, count := range after.Counters {
		if strings.HasPrefix(name, prefix) && count != before.Counters[name] {
			reasons = append(reasons, strings.TrimSuffix(strings.TrimPrefix(name, prefix), "}"))
		}
	}
	slices.Sort(reasons)
	return reasons
}

// expectStaleModels checks the status count and then the gauge, which reads the
// status through a one-second cache.
func (f *modelRevisionFixture) expectStaleModels(t *testing.T, want int) {
	t.Helper()
	if stale := f.srv.ExactCacheStatusSnapshot().ArtifactAllowlist.StaleModels; stale != want {
		t.Errorf("stale_models=%d, want %d", stale, want)
	}
	gauge := func() float64 {
		return f.srv.observation.Metrics().Snapshot().Gauges["exact_cache_artifact_allowlist_stale_models"]
	}
	if !waitForCond(3*time.Second, func() bool { return gauge() == float64(want) }) {
		t.Errorf("stale gauge=%v, want %d", gauge(), want)
	}
}

type modelRevisionSidecarState struct {
	Plans        int    `json:"plans"`
	LastContract string `json:"last_contract"`
}

func (f *modelRevisionFixture) sidecarState(t *testing.T) modelRevisionSidecarState {
	t.Helper()
	response, err := f.sidecar.Get("http://sidecar/test/state")
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	var state modelRevisionSidecarState
	if response.StatusCode != http.StatusOK || json.NewDecoder(response.Body).Decode(&state) != nil {
		t.Fatalf("sidecar stand-in state unavailable: HTTP %d", response.StatusCode)
	}
	return state
}

const modelRevisionSidecarEnv = "DARKBLOOM_MODEL_REVISION_SIDECAR"

// The supervised child implements only the sidecar's transport: it loads the
// contract set the controller submits to the continuity preload endpoint and
// answers plans for members of that set. It records every plan call it
// receives. Rendering and tokenization belong to the sidecar's own tests.
func TestModelRevisionSidecarProcess(t *testing.T) {
	if os.Getenv(modelRevisionSidecarEnv) != "1" {
		t.Skip("supervised sidecar subprocess only")
	}
	var socket string
	for i := 1; i+1 < len(os.Args); i++ {
		if os.Args[i] == "--socket" {
			socket = os.Args[i+1]
		}
	}
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(socket, 0o600); err != nil {
		_ = listener.Close()
		t.Fatal(err)
	}
	var mu sync.Mutex
	var state modelRevisionSidecarState
	loaded := map[string]bool{}
	mux := http.NewServeMux()
	mux.HandleFunc("/health", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusOK) })
	mux.HandleFunc("/ready", func(w http.ResponseWriter, _ *http.Request) {
		mu.Lock()
		ready := len(loaded) > 0
		mu.Unlock()
		if !ready {
			w.WriteHeader(http.StatusServiceUnavailable)
		}
		_ = json.NewEncoder(w).Encode(promptcontract.ReadinessStatus{Status: "ready", Ready: ready})
	})
	mux.HandleFunc("/v2/preload", func(w http.ResponseWriter, r *http.Request) {
		var request struct {
			IDs []string `json:"prompt_contract_ids"`
		}
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<16)).Decode(&request); err != nil || len(request.IDs) == 0 {
			http.Error(w, "invalid preload", http.StatusBadRequest)
			return
		}
		report := promptcontract.PreloadReport{
			ContinuityVersion: 1, Status: "ready", Ready: true, Requested: len(request.IDs), Warm: len(request.IDs),
		}
		mu.Lock()
		loaded = make(map[string]bool, len(request.IDs))
		for _, id := range request.IDs {
			loaded[id] = true
			report.Results = append(report.Results, promptcontract.PreloadResult{PromptContractID: id, Status: "warm"})
		}
		mu.Unlock()
		_ = json.NewEncoder(w).Encode(report)
	})
	mux.HandleFunc("/v1/plan", func(w http.ResponseWriter, r *http.Request) {
		var request struct {
			Contract string `json:"prompt_contract_id"`
		}
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20)).Decode(&request); err != nil {
			http.Error(w, "invalid plan", http.StatusBadRequest)
			return
		}
		mu.Lock()
		state.Plans, state.LastContract = state.Plans+1, request.Contract
		known := loaded[request.Contract]
		mu.Unlock()
		if !known {
			http.Error(w, "contract not loaded", http.StatusServiceUnavailable)
			return
		}
		hash := strings.Repeat("c", 64)
		_ = json.NewEncoder(w).Encode(promptcontract.Plan{
			PromptContractID: request.Contract, PromptTokenCount: 257,
			BlockBoundaries:       []promptcontract.Boundary{{TokenCount: 256, ChainHash: hash}},
			LastCompleteBlockHash: &hash,
		})
	})
	mux.HandleFunc("/test/state", func(w http.ResponseWriter, _ *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		_ = json.NewEncoder(w).Encode(state)
	})
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()
	server := &http.Server{Handler: mux, ReadHeaderTimeout: time.Second}
	served := make(chan error, 1)
	go func() { served <- server.Serve(listener) }()
	select {
	case <-ctx.Done():
		_ = server.Close()
		<-served
	case err := <-served:
		t.Fatalf("sidecar stand-in stopped serving: %v", err)
	}
}
