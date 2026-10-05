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
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	inference "github.com/eigeninference/d-inference/coordinator/api/inference"
	"github.com/eigeninference/d-inference/coordinator/internal/inference/routeplan"
	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/coordinator/store"
	"github.com/eigeninference/d-inference/coordinator/store/memory"
)

type cachePlanningHelperState struct {
	Ready        bool            `json:"ready"`
	Plans        int             `json:"plans"`
	Active       int             `json:"active"`
	Canceled     int             `json:"canceled"`
	Preloads     int             `json:"preloads"`
	LastContract string          `json:"last_contract"`
	LastScope    string          `json:"last_scope"`
	LastBody     json.RawMessage `json:"last_body,omitempty"`
}

// This child implements only a synthetic sidecar transport contract. Real
// rendering/tokenization and Rust worker behavior require separate tests.
func TestCachePlanningHelperProcess(t *testing.T) {
	if os.Getenv("DARKBLOOM_PLANNING_HELPER") != "1" {
		t.Skip("owned Supervisor subprocess only")
	}
	args := map[string]string{}
	for i := 1; i+1 < len(os.Args); i++ {
		if strings.HasPrefix(os.Args[i], "--") && len(os.Args[i]) > 2 {
			args[os.Args[i]] = os.Args[i+1]
			i++
		}
	}
	listener, err := net.Listen("unix", args["--socket"])
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(args["--socket"], 0o600); err != nil {
		_ = listener.Close()
		t.Fatal(err)
	}
	var mu sync.Mutex
	state := cachePlanningHelperState{}
	mode := "normal"
	loaded := map[string]bool{}
	mux := http.NewServeMux()
	mux.HandleFunc("/health", func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusOK) })
	mux.HandleFunc("/ready", func(w http.ResponseWriter, _ *http.Request) {
		mu.Lock()
		ready := state.Ready
		mu.Unlock()
		if !ready {
			w.WriteHeader(http.StatusServiceUnavailable)
		}
		_ = json.NewEncoder(w).Encode(promptcontract.ReadinessStatus{Status: "ready", Ready: ready})
	})
	mux.HandleFunc("/v1/preload", func(w http.ResponseWriter, r *http.Request) {
		var request struct {
			IDs []string `json:"prompt_contract_ids"`
		}
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&request); err != nil || len(request.IDs) != 1 {
			http.Error(w, "invalid fixture preload", http.StatusBadRequest)
			return
		}
		mu.Lock()
		loaded = map[string]bool{request.IDs[0]: true}
		state.Ready, state.Preloads = true, state.Preloads+1
		mu.Unlock()
		_ = json.NewEncoder(w).Encode(promptcontract.PreloadReport{
			Status: "ready", Ready: true, Requested: 1, Warm: 1,
			Results: []promptcontract.PreloadResult{{PromptContractID: request.IDs[0], Status: "warm"}},
		})
	})
	mux.HandleFunc("/metrics", func(w http.ResponseWriter, _ *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		status := "starting"
		if state.Ready {
			status = "ok"
		}
		_ = json.NewEncoder(w).Encode(promptcontract.SidecarStatus{
			Status: status, Ready: state.Ready, LoadedContracts: len(loaded),
			MaxLoadedContracts: 1, MaxPlanningConcurrency: 1, PlanningPermitsAvailable: 1 - state.Active,
		})
	})
	mux.HandleFunc("/test/state", func(w http.ResponseWriter, _ *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		_ = json.NewEncoder(w).Encode(state)
	})
	mux.HandleFunc("/test/mode", func(w http.ResponseWriter, r *http.Request) {
		value := r.URL.Query().Get("value")
		if r.Method != http.MethodPost || (value != "normal" && value != "block" && value != "delayed") {
			http.Error(w, "invalid fixture control", http.StatusBadRequest)
			return
		}
		mu.Lock()
		mode = value
		mu.Unlock()
		w.WriteHeader(http.StatusNoContent)
	})
	mux.HandleFunc("/v1/plan", func(w http.ResponseWriter, r *http.Request) {
		var request struct {
			Contract string          `json:"prompt_contract_id"`
			Scope    string          `json:"scope_id"`
			Body     json.RawMessage `json:"body"`
		}
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20)).Decode(&request); err != nil {
			http.Error(w, "invalid fixture plan", http.StatusBadRequest)
			return
		}
		mu.Lock()
		if !loaded[request.Contract] {
			mu.Unlock()
			http.Error(w, "not ready", http.StatusServiceUnavailable)
			return
		}
		state.Plans++
		state.Active++
		state.LastContract, state.LastScope = request.Contract, request.Scope
		state.LastBody = append(json.RawMessage(nil), request.Body...)
		selectedMode := mode
		mu.Unlock()
		defer func() { mu.Lock(); state.Active--; mu.Unlock() }()
		if selectedMode != "normal" {
			var release <-chan time.Time
			if selectedMode == "delayed" {
				timer := time.NewTimer(900 * time.Millisecond)
				defer timer.Stop()
				release = timer.C
			}
			select {
			case <-r.Context().Done():
				mu.Lock()
				state.Canceled++
				mu.Unlock()
				return
			case <-release:
			}
		}
		hash := strings.Repeat("c", 64)
		_ = json.NewEncoder(w).Encode(promptcontract.Plan{
			PromptContractID: request.Contract, PromptTokenCount: 257,
			BlockBoundaries:       []promptcontract.Boundary{{TokenCount: 256, ChainHash: hash}},
			LastCompleteBlockHash: &hash,
		})
	})
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()
	server := &http.Server{Handler: mux, ReadHeaderTimeout: time.Second}
	serveDone := make(chan error, 1)
	go func() { serveDone <- server.Serve(listener) }()
	select {
	case <-ctx.Done():
		_ = server.Close()
		<-serveDone
	case err := <-serveDone:
		t.Fatalf("fixture server ended unexpectedly: %v", err)
	}
}

type cachePlanningUDSFixture struct {
	model, contract, aggregate string
	manifest                   promptcontract.Manifest
	provisioner                *promptcontract.Provisioner
	supervisor                 *promptcontract.Supervisor
	controller                 *promptcontract.PreloadController
	control                    *http.Client
}

type cachePlanningFixtureOptions struct {
	model           string
	deferReadiness  bool
	artifactHandler func(http.ResponseWriter, *http.Request, []byte)
	realSidecar     *cachePlanningRealSidecarOptions
}

// newCachePlanningOwner is a real inference owner with its own registry and
// observation sinks, outside the HTTP composition.
func newCachePlanningOwner(t *testing.T) *ownerFixture {
	t.Helper()
	f := newOwnerFixture(registry.New(quietLogger()), memory.NewMemory(store.Config{}), quietLogger())
	t.Cleanup(f.Close)
	return f
}

// The fixture binds its prompt resources to the real owner exactly as
// application assembly does, and publishes its catalog on the shared registry.
func newCachePlanningUDSFixture(t *testing.T, s *inference.Owner, reg *registry.Registry, providerIDs ...string) *cachePlanningUDSFixture {
	t.Helper()
	return newCachePlanningUDSFixtureWithOptions(t, s, reg, cachePlanningFixtureOptions{}, providerIDs...)
}

func newCachePlanningUDSFixtureWithOptions(t *testing.T, s *inference.Owner, reg *registry.Registry, options cachePlanningFixtureOptions, providerIDs ...string) *cachePlanningUDSFixture {
	t.Helper()
	parent := "/tmp"
	if options.realSidecar != nil {
		cachePlanningVerifyRealBinary(t, options.realSidecar.binary, options.realSidecar.sha256)
		if os.Getenv("DARKBLOOM_PLANNING_TEST_UDS_PARENT") == "" {
			t.Fatal("real sidecar requires its allocated short UDS parent")
		}
	}
	if configured, present := os.LookupEnv("DARKBLOOM_PLANNING_TEST_UDS_PARENT"); present {
		if configured == "" || !filepath.IsAbs(configured) {
			t.Fatal("planning test socket parent must be an existing absolute directory")
		}
		parent = configured
	}
	base, err := filepath.EvalSymlinks(parent)
	if err != nil {
		t.Fatal(err)
	}
	if parent != "/tmp" && base != filepath.Clean(parent) {
		t.Fatal("planning test socket parent must be canonical")
	}
	if options.realSidecar != nil {
		info, err := os.Lstat(parent)
		if err != nil || !info.IsDir() || info.Mode().Perm()&0o077 != 0 || base != parent {
			t.Fatal("real sidecar UDS parent must be canonical and private")
		}
	}
	root, err := os.MkdirTemp(base, "cache-plan-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		// Verified artifacts are read-only. Restore only this owned fixture's
		// permissions; Walk never descends through a symlink.
		_ = filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
			if err != nil {
				return err
			}
			if info.Mode()&os.ModeSymlink != 0 {
				return nil
			}
			return os.Chmod(path, 0o700)
		})
		if err := os.RemoveAll(root); err != nil {
			t.Errorf("remove owned planning fixture: %v", err)
		}
		if options.realSidecar != nil {
			if _, err := os.Lstat(root); !os.IsNotExist(err) {
				t.Errorf("owned real planning fixture remains: %v", err)
			}
		}
	})
	payload := []byte(`{"version":"1.0"}`)
	digest := sha256.Sum256(payload)
	aggregate := sha256.Sum256(digest[:])
	files := []promptcontract.Artifact{{Path: "tokenizer.json", Role: "tokenizer", SizeBytes: int64(len(payload)), SHA256: hex.EncodeToString(digest[:])}}
	contract, err := promptcontract.ContractID(files, promptcontract.CurrentVersions())
	if err != nil {
		t.Fatal(err)
	}
	model := options.model
	if model == "" {
		model = "planning-fixture"
	}
	f := &cachePlanningUDSFixture{model: model, contract: contract, aggregate: hex.EncodeToString(aggregate[:])}
	f.manifest = promptcontract.Manifest{ModelID: model, R2Prefix: "models/" + model, AggregateSHA256: f.aggregate, Files: files}
	manifests := []promptcontract.Manifest{f.manifest}
	payloads := map[string][]byte{"/" + f.manifest.R2Prefix + "/tokenizer.json": payload}
	if real := options.realSidecar; real != nil {
		if len(real.artifacts) == 0 {
			t.Fatal("real sidecar requires explicit verified-artifact fixtures")
		}
		manifests, payloads = nil, make(map[string][]byte)
		for _, artifact := range real.artifacts {
			manifests = append(manifests, artifact.manifest)
			for name, contents := range artifact.files {
				payloads["/"+artifact.manifest.R2Prefix+"/"+name] = contents
			}
		}
		f.manifest = manifests[0]
		f.model, f.aggregate = f.manifest.ModelID, f.manifest.AggregateSHA256
		artifacts, err := promptcontract.PromptArtifacts(f.manifest.Files)
		if err != nil {
			t.Fatal(err)
		}
		f.contract, err = promptcontract.ContractID(artifacts, promptcontract.CurrentVersions())
		if err != nil {
			t.Fatal(err)
		}
	}
	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		payload, exists := payloads[r.URL.Path]
		if !exists {
			http.NotFound(w, r)
			return
		}
		if options.artifactHandler != nil {
			options.artifactHandler(w, r, payload)
			return
		}
		_, _ = w.Write(payload)
	}))
	t.Cleanup(origin.Close)
	originURL, err := url.Parse(origin.URL + "/")
	if err != nil {
		t.Fatal(err)
	}
	artifactRoot := filepath.Join(root, "artifacts")
	artifactConfig := promptcontract.ArtifactCacheConfig{Root: artifactRoot, BaseURL: originURL, HTTPClient: origin.Client(), AllowHTTP: true}
	if options.realSidecar != nil {
		artifactConfig.DownloadTimeout = 45 * time.Second
	}
	cache, err := promptcontract.NewArtifactCache(artifactConfig)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	if options.realSidecar != nil {
		cancel()
		ctx, cancel = context.WithTimeout(context.Background(), 45*time.Second)
	}
	t.Cleanup(cancel)
	provisionConfig := promptcontract.ProvisionerConfig{MaxConcurrent: 1, MaxModels: 1}
	if options.realSidecar != nil {
		provisionConfig = promptcontract.ProvisionerConfig{MaxConcurrent: 2, MaxModels: 8}
	}
	provisioner, err := promptcontract.NewProvisioner(ctx, cache, provisionConfig)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(provisioner.Close)
	f.provisioner = provisioner
	if err := provisioner.Reconcile(manifests); err != nil {
		t.Fatal(err)
	}
	launcher := filepath.Join(root, "sidecar-helper")
	if real := options.realSidecar; real != nil {
		launcher = real.binary
		t.Cleanup(func() { cachePlanningVerifyRealBinary(t, real.binary, real.sha256) })
	} else {
		executable, err := os.Executable()
		if err != nil {
			t.Fatal(err)
		}
		quotedExecutable := "'" + strings.ReplaceAll(executable, "'", "'\"'\"'") + "'"
		script := "#!/bin/sh\nDARKBLOOM_PLANNING_HELPER=1 exec " + quotedExecutable + " -test.run=^TestCachePlanningHelperProcess$ -test.timeout=30s -- \"$@\"\n"
		if err := os.WriteFile(launcher, []byte(script), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	socket := filepath.Join(root, "s.sock")
	supervisorConfig := promptcontract.SupervisorConfig{
		Enabled: true, BinaryPath: launcher, SocketPath: socket, ArtifactRoot: artifactRoot,
		MaxConcurrency: 1, MaxConnections: 8, MaxLoadedContracts: 1,
		RequestTimeout: 2 * time.Second, HealthTimeout: 250 * time.Millisecond, PreloadTimeout: time.Second,
		StartupTimeout: 5 * time.Second, HealthInterval: 20 * time.Millisecond, ShutdownTimeout: time.Second,
	}
	if options.realSidecar != nil {
		supervisorConfig.MaxLoadedContracts = 8
		supervisorConfig.HealthTimeout, supervisorConfig.PreloadTimeout = time.Second, 5*time.Second
		supervisorConfig.ShutdownTimeout = 3 * time.Second // Rust's keep-alive drain can take two seconds.
	}
	f.supervisor = promptcontract.NewSupervisor(supervisorConfig)
	t.Cleanup(func() {
		f.supervisor.Close()
		if options.realSidecar != nil {
			if status := f.supervisor.Status(); status.Running || status.Ready {
				t.Error("real planner child was not drained")
			}
			if _, err := os.Lstat(socket); !os.IsNotExist(err) {
				t.Errorf("real planner socket remains: %v", err)
			}
		}
	})
	f.supervisor.Start(ctx)
	if options.realSidecar != nil {
		// Isolate the intended tokenizer/artifact condition from child startup.
		// The long fixture-only backoff must not classify a not-yet-bound socket
		// as the failed tokenizer that this test is meant to observe.
		awaitCondition(t, 5*time.Second, func() bool {
			status := f.supervisor.Status()
			return status.Running && status.ChildGeneration > 0 && f.supervisor.Client().Health(ctx) == nil
		}, "real sidecar liveness before controlled preload")
	}
	preloadConfig := promptcontract.PreloadControllerConfig{PollInterval: 10 * time.Millisecond, MetricsInterval: 50 * time.Millisecond}
	if options.realSidecar != nil {
		preloadConfig.FailureBackoffMin, preloadConfig.FailureBackoffMax = time.Hour, time.Hour
	}
	f.controller, err = promptcontract.NewPreloadController(provisioner, f.supervisor, preloadConfig)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(f.controller.Close)
	if options.realSidecar != nil {
		t.Cleanup(cancel)
	} // Fatal paths cancel all owners before Close/join.
	f.controller.Start(ctx)
	s.SetPromptArtifactProvisioner(provisioner)
	s.SetPromptContractClient(f.supervisor.Client())
	s.SetPromptPreloadController(f.controller)
	s.SetPromptSupervisor(f.supervisor)
	configureCachePreparationTest(t, reg)
	hashes, catalog := make(map[string]string), make([]registry.CatalogEntry, 0, len(manifests))
	for _, manifest := range manifests {
		hashes[manifest.ModelID] = manifest.AggregateSHA256
		catalog = append(catalog, registry.CatalogEntry{ID: manifest.ModelID, WeightHash: manifest.AggregateSHA256})
	}
	for _, providerID := range providerIDs {
		reg.UpdateModelWeightHashes(providerID, hashes)
	}
	reg.SetModelCatalog(catalog)
	transport := &http.Transport{DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, "unix", socket)
	}}
	t.Cleanup(transport.CloseIdleConnections)
	f.control = &http.Client{Transport: transport, Timeout: time.Second}
	if !options.deferReadiness {
		f.waitReady(t)
	}
	return f
}

func (f *cachePlanningUDSFixture) waitReady(t *testing.T) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for !f.controller.ReadyFor(f.contract) {
		if time.Now().After(deadline) {
			t.Fatalf("fixture not ready: supervisor=%+v preload=%+v", f.supervisor.Status(), f.controller.Status())
		}
		time.Sleep(10 * time.Millisecond)
	}
	status, ok := f.provisioner.Status(f.model)
	if !ok || !status.ArtifactReady || status.PromptContractID != f.contract || status.ModelAggregateSHA256 != f.aggregate || status.Path == "" {
		t.Fatal("fixture did not complete actual verified artifact provisioning")
	}
}

func (f *cachePlanningUDSFixture) state(t *testing.T) cachePlanningHelperState {
	t.Helper()
	response, err := f.control.Get("http://fixture/test/state")
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	var state cachePlanningHelperState
	if response.StatusCode != http.StatusOK {
		t.Fatalf("fixture state status=%d", response.StatusCode)
	}
	if err := json.NewDecoder(response.Body).Decode(&state); err != nil {
		t.Fatal(err)
	}
	return state
}

func (f *cachePlanningUDSFixture) input() routeplan.CachePlanningInput {
	return routeplan.CachePlanningInput{Account: "planning-account", Model: f.model,
		Body: []byte(`{"messages":[{"role":"user","content":"synthetic planning fixture"}]}`)}
}

func (f *cachePlanningUDSFixture) setMode(t *testing.T, mode string) {
	t.Helper()
	request, err := http.NewRequest(http.MethodPost, "http://fixture/test/mode?value="+url.QueryEscape(mode), nil)
	if err != nil {
		t.Fatal(err)
	}
	response, err := f.control.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusNoContent {
		t.Fatalf("fixture mode status=%d", response.StatusCode)
	}
}

func (f *cachePlanningUDSFixture) waitState(t *testing.T, predicate func(cachePlanningHelperState) bool) cachePlanningHelperState {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for {
		state := f.state(t)
		if predicate(state) {
			return state
		}
		if time.Now().After(deadline) {
			t.Fatalf("fixture did not reach required state: %+v", state)
		}
		time.Sleep(5 * time.Millisecond)
	}
}
