package promptcontract

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// Opt-in actual Rust services only. The qualification runner must bind the Go
// source tree and each Rust compiler-artifact/source receipt independently.
// The same public-API-compatible file can be overlaid on PR19 Go with the legacy
// oracle; changing an environment label alone does not prove old Go provenance.
type actualReadinessBinary struct {
	version, path, digest string
}

func actualReadinessBindings(t *testing.T) ([]actualReadinessBinary, bool) {
	t.Helper()
	if os.Getenv("DARKBLOOM_TEST_PROMPT_SIDECAR") == "" {
		t.Skip("requires explicitly bound actual candidate/legacy Rust service binaries")
	}
	goVersion := os.Getenv("DARKBLOOM_TEST_PROMPT_GO_VERSION")
	if goVersion != "candidate" && goVersion != "legacy" {
		t.Fatal("bind DARKBLOOM_TEST_PROMPT_GO_VERSION to the qualification's actual Go source")
	}
	var binaries []actualReadinessBinary
	for _, item := range []struct{ version, variable string }{
		{"candidate", "DARKBLOOM_TEST_PROMPT_SIDECAR"},
		{"legacy", "DARKBLOOM_TEST_PROMPT_SIDECAR_LEGACY"},
	} {
		binary := actualReadinessBinary{item.version, os.Getenv(item.variable), os.Getenv(item.variable + "_SHA256")}
		actualReadinessVerifyBinary(t, binary)
		binaries = append(binaries, binary)
	}
	if binaries[0].digest == binaries[1].digest {
		t.Fatal("candidate and legacy Rust controls must not be the same executable")
	}
	return binaries, goVersion == "candidate"
}

func actualReadinessVerifyBinary(t *testing.T, binary actualReadinessBinary) {
	t.Helper()
	resolved, err := filepath.EvalSymlinks(binary.path)
	if err != nil || !filepath.IsAbs(binary.path) || filepath.Clean(binary.path) != binary.path ||
		resolved != binary.path || filepath.Base(binary.path) != "promptsidecar" || !validHash(binary.digest) {
		t.Fatalf("%s service binary needs a canonical explicit path and SHA256: %v", binary.version, err)
	}
	info, err := os.Lstat(binary.path)
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm()&0o111 == 0 || info.Size() > 256<<20 {
		t.Fatalf("%s service binary is not a bounded executable regular file: %v", binary.version, err)
	}
	file, err := os.Open(binary.path)
	if err != nil {
		t.Fatal(err)
	}
	hash := sha256.New()
	_, readErr := io.Copy(hash, io.LimitReader(file, info.Size()+1))
	closeErr := file.Close()
	after, statErr := os.Lstat(binary.path)
	if readErr != nil || closeErr != nil || statErr != nil || !os.SameFile(info, after) ||
		info.Size() != after.Size() || !info.ModTime().Equal(after.ModTime()) || hex.EncodeToString(hash.Sum(nil)) != binary.digest {
		t.Fatalf("%s source-bound service binary changed", binary.version)
	}
	if strings.Contains(binary.path, string(filepath.Separator)+"deps"+string(filepath.Separator)) {
		t.Fatal("a libtest executable is not the actual sidecar service")
	}
}

type actualReadinessCaller struct{}
type actualReadinessRoundTrip func(*http.Request) (*http.Response, error)

func (f actualReadinessRoundTrip) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

// A gate holds one genuine transport call or its genuine response. It never
// supplies fake readiness, report bytes, status, or a replacement Rust child.
type actualReadinessGate struct {
	afterResponse              bool
	entered, release, canceled chan struct{}
	releaseOnce                sync.Once
}

func (g *actualReadinessGate) open() { g.releaseOnce.Do(func() { close(g.release) }) }
func (g *actualReadinessGate) wait(ctx context.Context) error {
	close(g.entered)
	select {
	case <-ctx.Done():
		close(g.canceled)
		return ctx.Err()
	case <-g.release:
		return nil
	}
}

type actualReadinessWire struct {
	mu                    sync.Mutex
	gate                  *actualReadinessGate
	healthFailures        atomic.Int64
	controllerReadyCalls  atomic.Int64
	controllerReadyStatus atomic.Int64
}

func (w *actualReadinessWire) hold(afterResponse bool) *actualReadinessGate {
	g := &actualReadinessGate{afterResponse: afterResponse, entered: make(chan struct{}), release: make(chan struct{}), canceled: make(chan struct{})}
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.gate != nil {
		panic("one actual preload transport gate at a time")
	}
	w.gate = g
	return g
}

func (w *actualReadinessWire) install(client *Client) {
	health, control := client.healthHTTP.Transport, client.controlHTTP.Transport
	client.healthHTTP.Transport = actualReadinessRoundTrip(func(r *http.Request) (*http.Response, error) {
		if r.URL.Path == "/health" && r.Context().Value(actualReadinessCaller{}) == "supervisor" {
			for remaining := w.healthFailures.Load(); remaining > 0; remaining = w.healthFailures.Load() {
				if w.healthFailures.CompareAndSwap(remaining, remaining-1) {
					return nil, errors.New("test-local liveness transport interruption")
				}
			}
		}
		response, err := health.RoundTrip(r)
		if r.URL.Path == "/ready" && r.Context().Value(actualReadinessCaller{}) == "controller" {
			w.controllerReadyCalls.Add(1)
			if response != nil {
				w.controllerReadyStatus.Store(int64(response.StatusCode))
			}
		}
		return response, err
	})
	client.controlHTTP.Transport = actualReadinessRoundTrip(func(r *http.Request) (*http.Response, error) {
		w.mu.Lock()
		gate := w.gate
		w.gate = nil
		w.mu.Unlock() // Never hold the test lock while waiting or doing real IO.
		if gate != nil && !gate.afterResponse {
			if err := gate.wait(r.Context()); err != nil {
				return nil, err
			}
		}
		response, err := control.RoundTrip(r)
		if gate != nil && gate.afterResponse && err == nil {
			if waitErr := gate.wait(r.Context()); waitErr != nil {
				_ = response.Body.Close()
				return nil, waitErr
			}
		}
		return response, err
	})
}

type actualReadinessFixture struct {
	ctx         context.Context
	cancel      context.CancelFunc
	provisioner *Provisioner
	supervisor  *Supervisor
	controller  *PreloadController
	wire        *actualReadinessWire
	manifests   map[string]Manifest
	ids         map[string]string
	socket      string
	binary      actualReadinessBinary
	closed      sync.Once
}

func newActualReadinessFixture(t *testing.T, binary actualReadinessBinary) *actualReadinessFixture {
	t.Helper()
	actualReadinessVerifyBinary(t, binary)
	parent := os.Getenv("DARKBLOOM_PLANNING_TEST_UDS_PARENT")
	resolved, err := filepath.EvalSymlinks(parent)
	if err != nil || !filepath.IsAbs(parent) || filepath.Clean(parent) != parent || resolved != parent {
		t.Fatal("actual-sidecar fixture requires the allocated canonical short UDS parent")
	}
	parentInfo, err := os.Lstat(parent)
	if err != nil || !parentInfo.IsDir() || parentInfo.Mode().Perm()&0o077 != 0 {
		t.Fatal("actual-sidecar UDS parent must be a private directory")
	}
	socketRoot, err := os.MkdirTemp(parent, "pc-real-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := os.RemoveAll(socketRoot); err != nil {
			t.Errorf("owned socket fixture cleanup: %v", err)
		}
		if _, err := os.Lstat(socketRoot); !os.IsNotExist(err) {
			t.Errorf("owned socket directory remains: %v", err)
		}
	})
	root := readOnlyTempRoot(t)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	f := &actualReadinessFixture{ctx: ctx, cancel: cancel, manifests: make(map[string]Manifest),
		ids: make(map[string]string), wire: &actualReadinessWire{}, socket: filepath.Join(socketRoot, "s.sock"), binary: binary}
	t.Cleanup(func() { f.close(t) })
	files := make(map[string][]byte)
	for _, model := range []string{"a", "b", "c"} {
		tokenizer := []byte(`{"version":"1.0","truncation":null,"padding":null,"added_tokens":[],"normalizer":null,"pre_tokenizer":{"type":"Whitespace"},"post_processor":null,"decoder":null,"model":{"type":"WordLevel","vocab":{"[UNK]":0,"user":1,"hello":2,"world":3,"assistant":4,":":5},"unk_token":"[UNK]"}}`)
		if model == "b" {
			tokenizer = []byte(`{"not_a_tokenizer":true}`)
		}
		contents := map[string][]byte{
			"tokenizer.json":        tokenizer,
			"tokenizer_config.json": []byte(`{"chat_template":"{% for message in messages %}{{ message.role }}:{{ message.content }}\n{% endfor %}{% if add_generation_prompt %}assistant:{% endif %}"}`),
			"config.json":           []byte(fmt.Sprintf(`{"model_type":"fixture","variant":"%s"}`, model)),
		}
		manifest := fixtureManifest(contents)
		manifest.ModelID, manifest.ModelType, manifest.R2Prefix = "fixture-"+model, "fixture", "fixture-"+model
		for i := range manifest.Files {
			if manifest.Files[i].Path == "tokenizer_config.json" {
				manifest.Files[i].Role = "tokenizer"
			}
		}
		artifacts, err := PromptArtifacts(manifest.Files)
		if err != nil {
			t.Fatal(err)
		}
		id, err := ContractID(artifacts, CurrentVersions())
		if err != nil {
			t.Fatal(err)
		}
		f.manifests[model], f.ids[model] = manifest, id
		for name, value := range contents {
			files["/"+manifest.R2Prefix+"/"+name] = value
		}
	}
	base, _ := url.Parse("https://readiness.invalid/")
	cache, err := NewArtifactCache(ArtifactCacheConfig{Root: root, BaseURL: base, DownloadTimeout: 3 * time.Second,
		HTTPClient: &http.Client{Transport: actualReadinessRoundTrip(func(r *http.Request) (*http.Response, error) {
			value, ok := files[r.URL.Path]
			if r.Method != http.MethodGet || r.URL.Scheme != "https" || r.URL.Host != "readiness.invalid" || !ok {
				return nil, errors.New("artifact fixture forbids external IO")
			}
			return &http.Response{StatusCode: http.StatusOK, Header: make(http.Header), Request: r,
				ContentLength: int64(len(value)), Body: io.NopCloser(bytes.NewReader(value))}, nil
		})}})
	if err != nil {
		t.Fatal(err)
	}
	f.provisioner, err = NewProvisioner(ctx, cache, ProvisionerConfig{MaxConcurrent: 2, MaxModels: 8})
	if err != nil {
		t.Fatal(err)
	}
	f.supervisor = NewSupervisor(SupervisorConfig{Enabled: true, BinaryPath: binary.path, SocketPath: f.socket, ArtifactRoot: root,
		MaxConcurrency: 2, MaxLoadedContracts: 8, MaxConnections: 8, MaxTokens: 8192, MemoryLimitMiB: 1024,
		RequestTimeout: 2 * time.Second, PreloadTimeout: 5 * time.Second, HealthTimeout: time.Second,
		HealthInterval: 50 * time.Millisecond, HealthFailureThreshold: 2, StartupTimeout: 5 * time.Second,
		// Rust allows up to two seconds to drain existing keep-alive connections.
		// Keep a bounded grace beyond that so its socket guard can unlink normally.
		ShutdownTimeout: 3 * time.Second, RestartBackoffMin: 20 * time.Millisecond, RestartBackoffMax: 100 * time.Millisecond})
	f.wire.install(f.supervisor.Client())
	f.controller, err = NewPreloadController(f.provisioner, f.supervisor, PreloadControllerConfig{
		PollInterval: 20 * time.Millisecond, MetricsInterval: time.Hour, FailureBackoffMin: time.Hour, FailureBackoffMax: time.Hour})
	if err != nil {
		t.Fatal(err)
	}
	f.supervisor.Start(context.WithValue(ctx, actualReadinessCaller{}, "supervisor"))
	actualReadinessWait(t, "real sidecar liveness", func() bool {
		return f.supervisor.Status().Running && f.supervisor.Status().ChildGeneration > 0 && f.supervisor.Client().Health(ctx) == nil
	})
	return f
}

func actualReadinessWait(t *testing.T, what string, predicate func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if predicate() {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatal("timed out: " + what)
}

func actualReadinessAwait(t *testing.T, what string, done <-chan struct{}) {
	t.Helper()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("timed out: " + what)
	}
}

func (f *actualReadinessFixture) close(t *testing.T) {
	t.Helper()
	f.closed.Do(func() {
		f.cancel() // Independent fallback precedes every public Close/join.
		if f.controller != nil {
			f.controller.Close()
		}
		if f.provisioner != nil {
			f.provisioner.Close()
		}
		if f.supervisor != nil {
			f.supervisor.Close() // Owns termination and cmd.Wait of the actual Rust child.
			if status := f.supervisor.Status(); status.Running || status.Ready {
				t.Error("Supervisor.Close did not drain its child")
			}
			if _, err := os.Lstat(f.socket); !os.IsNotExist(err) {
				t.Errorf("owned Rust socket remains after graceful close: %v", err)
			}
		}
		actualReadinessVerifyBinary(t, f.binary)
	})
}

func (f *actualReadinessFixture) provision(t *testing.T, models ...string) {
	t.Helper()
	var manifests []Manifest
	for _, model := range models {
		manifests = append(manifests, f.manifests[model])
	}
	if err := f.provisioner.Reconcile(manifests); err != nil {
		t.Fatal(err)
	}
	actualReadinessWait(t, "real artifact verification", func() bool {
		s := f.provisioner.Snapshot()
		return s.Counts.Ready == len(models) && s.Counts.Pending == 0 && s.Counts.Failed == 0 && len(s.ContractIDs) == len(models)
	})
}

func (f *actualReadinessFixture) startController() {
	f.controller.Start(context.WithValue(f.ctx, actualReadinessCaller{}, "controller"))
}

func (f *actualReadinessFixture) plan(t *testing.T, model string, want bool) {
	t.Helper()
	body, _ := json.Marshal(map[string]any{"model": f.manifests[model].ModelID,
		"messages": []map[string]string{{"role": "user", "content": "hello"}}})
	plan, err := f.supervisor.Client().Plan(f.ctx, PlanInput{PromptContractID: f.ids[model],
		ScopeID: "actual-readiness-fixture", Endpoint: EndpointChatCompletions, Body: body})
	if want {
		if err != nil || plan.PromptTokenCount != 5 || plan.PromptContractID != f.ids[model] {
			t.Fatalf("actual %s plan: %+v %v", model, plan, err)
		}
	} else if err == nil || !strings.Contains(err.Error(), "HTTP 503") {
		t.Fatalf("actual %s must be Rust-not-ready, not an unrelated error: %v", model, err)
	}
}

func (f *actualReadinessFixture) runtime(t *testing.T, ready bool, runs, failed uint64) {
	t.Helper()
	response, err := f.supervisor.Client().healthGet(f.ctx, "/health")
	if err != nil {
		t.Fatal(err)
	}
	var health ReadinessStatus
	decodeErr := json.NewDecoder(io.LimitReader(response.Body, 4096)).Decode(&health)
	_ = response.Body.Close()
	if decodeErr != nil || response.StatusCode != http.StatusOK || health.Ready != ready {
		t.Fatalf("actual /health mismatch: %+v status=%d error=%v", health, response.StatusCode, decodeErr)
	}
	gotReady, err := f.supervisor.Client().Ready(f.ctx)
	if err != nil || gotReady != ready {
		t.Fatalf("actual /ready=%v error=%v want=%v", gotReady, err, ready)
	}
	status, err := f.supervisor.Client().Metrics(f.ctx)
	if err != nil || status.Ready != ready || status.Status != health.Status || status.Metrics.Preloads.Runs != runs || status.Metrics.Preloads.Failed != failed ||
		status.PlanningPermitsAvailable != 2 || status.LoadingContracts != 0 || status.MaxLoadedContracts != 8 {
		t.Fatalf("actual /metrics mismatch: %+v error=%v", status, err)
	}
}

func TestPreloadRealSidecarRuntimeAndMixedVersions(t *testing.T) {
	binaries, candidateGo := actualReadinessBindings(t)
	for _, binary := range binaries {
		t.Run(binary.version+"_rust", func(t *testing.T) {
			f := newActualReadinessFixture(t, binary)
			f.runtime(t, false, 0, 0) // Production listener cannot expose LegacyLazy.
			f.provision(t, "a", "b")  // B is hash-verified but cannot construct a tokenizer.
			report, err := f.supervisor.Client().Preload(f.ctx, []string{f.ids["a"], f.ids["b"]})
			if err != nil || report.Ready || report.Status != "degraded" || report.Requested != 2 || report.Cold != 1 || report.Warm != 0 || report.Failed != 1 {
				t.Fatalf("actual strict partial report: %+v error=%v", report, err)
			}
			candidateRust := binary.version == "candidate"
			f.runtime(t, candidateRust, 1, 1)
			f.plan(t, "a", candidateRust)
			f.plan(t, "b", false)
			f.startController()
			wantParticipation := candidateGo && candidateRust
			actualReadinessWait(t, "controller consumed actual partial report", func() bool {
				return f.controller.Status().Failures == 1 && f.controller.ReadyFor(f.ids["a"]) == wantParticipation
			})
			status := f.controller.Status()
			if status.Ready != wantParticipation || status.Runs != 0 || status.Cold != 0 || f.controller.ReadyFor(f.ids["b"]) ||
				(wantParticipation && (status.Warm != 1 || status.ContractCount != 1)) ||
				(!wantParticipation && (status.Warm != 0 || status.ContractCount != 0)) {
				t.Fatalf("mixed-version Go participation wrong: %+v", status)
			}
			wantCalls := int64(0)
			if candidateGo {
				wantCalls = 1
			}
			wantCode := int64(http.StatusServiceUnavailable)
			if candidateRust {
				wantCode = http.StatusOK
			}
			if f.wire.controllerReadyCalls.Load() != wantCalls || (candidateGo && f.wire.controllerReadyStatus.Load() != wantCode) {
				t.Fatal("partial publication did not use the required actual caller-context /ready result")
			}
			f.runtime(t, candidateRust, 2, 2)
			generation := f.provisioner.Snapshot().Generation
			if f.provisioner.Reconcile([]Manifest{{ModelID: "malformed"}}) == nil ||
				f.provisioner.Snapshot().Generation <= generation || f.controller.ReadyFor(f.ids["a"]) {
				t.Fatal("malformed real catalog did not immediately fence old participation")
			}
			actualReadinessWait(t, "invalid catalog closes Go status", func() bool { return !f.controller.Status().Ready })
			f.runtime(t, candidateRust, 2, 2) // Empty Go participation sends no empty Rust replacement.
			f.provision(t, "c")
			actualReadinessWait(t, "catalog replacement recovers C", func() bool { return f.controller.ReadyFor(f.ids["c"]) })
			if f.controller.ReadyFor(f.ids["a"]) || f.controller.ReadyFor(f.ids["b"]) || f.supervisor.Status().Restarts != 0 {
				t.Fatal("removed Go member reopened or readiness degradation restarted the real child")
			}
			f.plan(t, "c", true)
			if candidateRust {
				f.plan(t, "a", false)
			}
			f.runtime(t, true, 3, 2)
			f.close(t)
		})
	}
}

func TestPreloadRealSidecarGenerationAndCanceledResponseDrain(t *testing.T) {
	binaries, _ := actualReadinessBindings(t)
	f := newActualReadinessFixture(t, binaries[0])
	f.provision(t, "a")
	f.startController()
	actualReadinessWait(t, "initial real A participation", func() bool { return f.controller.ReadyFor(f.ids["a"]) })
	oldGeneration := f.supervisor.Status().ChildGeneration
	before := f.wire.hold(false)
	t.Cleanup(before.open)
	// Inject transport failure only, not a fake Rust response. The real Supervisor
	// must terminate/wait its real child and start another source-bound process.
	f.wire.healthFailures.Store(2)
	actualReadinessAwait(t, "new generation preload reached real-transport gate", before.entered)
	if f.supervisor.Status().ChildGeneration <= oldGeneration || f.supervisor.Status().Restarts != 1 || f.controller.ReadyFor(f.ids["a"]) {
		t.Fatal("actual child generation change retained old publication")
	}
	actualReadinessWait(t, "new child really listening before preload", func() bool {
		status := f.supervisor.Status()
		return status.ChildGeneration > oldGeneration && status.Restarts == 1 && f.supervisor.Client().Health(f.ctx) == nil
	})
	f.runtime(t, false, 0, 0)
	before.open()
	actualReadinessWait(t, "new child independently acknowledges A", func() bool { return f.controller.ReadyFor(f.ids["a"]) })
	f.runtime(t, true, 1, 0)
	after := f.wire.hold(true)
	t.Cleanup(after.open)
	f.provision(t, "c")
	actualReadinessAwait(t, "actual Rust preload response held before Go publication", after.entered)
	if f.controller.ReadyFor(f.ids["a"]) || f.controller.ReadyFor(f.ids["c"]) {
		t.Fatal("unconsumed response granted participation")
	}
	closed := make(chan struct{})
	go func() { f.controller.Close(); close(closed) }()
	actualReadinessAwait(t, "public controller close canceled held actual response", closed)
	actualReadinessAwait(t, "actual response transport observed cancellation", after.canceled)
	if f.controller.Status().Ready || f.controller.ReadyFor(f.ids["c"]) {
		t.Fatal("canceled real response published late")
	}
	// Rust loading finished before this response gate. Do not call this Rust
	// loader cancellation; that ownership case is covered by the real lib tests.
	f.runtime(t, true, 2, 0)
	f.close(t)
}
