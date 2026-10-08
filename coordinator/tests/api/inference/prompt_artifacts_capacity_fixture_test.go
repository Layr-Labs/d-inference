package inference_test

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/store"
)

// Uses only public lifecycle APIs the pre-selection controller also has. Overlay
// both capacity fixture/oracle files on that exact old Go tree for the red; a
// binary label is not source provenance.
type capacityActualRoundTrip func(*http.Request) (*http.Response, error)

func (f capacityActualRoundTrip) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

type capacityActualFixture struct {
	ctx                    context.Context
	cancel                 context.CancelFunc
	server                 *serverFixture
	http                   *httptest.Server
	provider               *failoverProvider
	provisioner            *promptcontract.Provisioner
	supervisor             *promptcontract.Supervisor
	controller             *promptcontract.PreloadController
	control                *http.Client
	models, ids            []string
	binary, digest, socket string
	closed                 sync.Once
}

func capacityActualBinary(t *testing.T) (string, string) {
	t.Helper()
	path := os.Getenv("DARKBLOOM_TEST_PROMPT_SIDECAR")
	if path == "" {
		t.Skip("requires an explicitly source-bound real promptsidecar service")
	}
	digest := os.Getenv("DARKBLOOM_TEST_PROMPT_SIDECAR_SHA256")
	capacityVerifyBinary(t, path, digest)
	return path, digest
}

func capacityVerifyBinary(t *testing.T, path, digest string) {
	t.Helper()
	resolved, err := filepath.EvalSymlinks(path)
	if err != nil || !filepath.IsAbs(path) || filepath.Clean(path) != path || resolved != path ||
		filepath.Base(path) != "promptsidecar" || len(digest) != 64 || strings.ToLower(digest) != digest ||
		strings.Contains(path, string(filepath.Separator)+"deps"+string(filepath.Separator)) {
		t.Fatal("capacity oracle needs canonical service executable and exact SHA256")
	}
	if _, err := hex.DecodeString(digest); err != nil {
		t.Fatal("invalid binary digest")
	}
	before, err := os.Lstat(path)
	if err != nil || !before.Mode().IsRegular() || before.Mode().Perm()&0o111 == 0 || before.Size() > 256<<20 {
		t.Fatal("sidecar is not a bounded executable regular file")
	}
	file, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	hash := sha256.New()
	_, readErr := io.Copy(hash, io.LimitReader(file, before.Size()+1))
	closeErr := file.Close()
	after, statErr := os.Lstat(path)
	if readErr != nil || closeErr != nil || statErr != nil || !os.SameFile(before, after) || before.Size() != after.Size() ||
		!before.ModTime().Equal(after.ModTime()) || hex.EncodeToString(hash.Sum(nil)) != digest {
		t.Fatal("source-bound service executable changed")
	}
}

func newCapacityActualFixture(t *testing.T, sharedNinth bool) *capacityActualFixture {
	t.Helper()
	binary, digest := capacityActualBinary(t)
	parent := os.Getenv("DARKBLOOM_PLANNING_TEST_UDS_PARENT")
	resolved, err := filepath.EvalSymlinks(parent)
	info, statErr := os.Lstat(parent)
	if err != nil || statErr != nil || !filepath.IsAbs(parent) || resolved != parent || filepath.Clean(parent) != parent ||
		!info.IsDir() || info.Mode().Perm()&0o077 != 0 {
		t.Fatal("requires allocated canonical private short UDS parent")
	}
	root, err := os.MkdirTemp(parent, "pc-cap-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
			if err != nil || info.Mode()&os.ModeSymlink != 0 {
				return err
			}
			return os.Chmod(path, 0o700)
		})
		if err := os.RemoveAll(root); err != nil {
			t.Errorf("owned capacity fixture cleanup: %v", err)
		}
	})
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	t.Cleanup(cancel) // Constructor failures cancel even before all owners attach.
	reg, memory, server, transport := setupTTFTFailoverServer(t)
	f := &capacityActualFixture{ctx: ctx, cancel: cancel, server: server, http: transport,
		binary: binary, digest: digest, socket: filepath.Join(root, "s.sock")}
	t.Cleanup(func() { f.close(t) })
	files := make(map[string][]byte)
	weights := make(map[string]string)
	var models []failoverModelSpec
	for index := 0; index < 9; index++ {
		variant := index
		if sharedNinth && index == 8 {
			variant = 0
		}
		model := fmt.Sprintf("capacity-fixture-%02d", index)
		contents := map[string][]byte{
			"config.json":           []byte(fmt.Sprintf(`{"model_type":"fixture","variant":%d}`, variant)),
			"tokenizer.json":        []byte(`{"version":"1.0","truncation":null,"padding":null,"added_tokens":[],"normalizer":null,"pre_tokenizer":{"type":"Whitespace"},"post_processor":null,"decoder":null,"model":{"type":"WordLevel","vocab":{"[UNK]":0,"user":1,"hello":2,"world":3,"assistant":4,":":5},"unk_token":"[UNK]"}}`),
			"tokenizer_config.json": []byte(`{"chat_template":"{% for message in messages %}{{ message.role }}:{{ message.content }}\n{% endfor %}{% if add_generation_prompt %}assistant:{% endif %}"}`),
		}
		var artifacts []promptcontract.Artifact
		var versionFiles []store.ModelVersionFile
		var names []string
		for name := range contents {
			names = append(names, name)
		}
		sort.Strings(names)
		aggregate := sha256.New()
		var total int64
		for _, name := range names {
			value := contents[name]
			digest := sha256.Sum256(value)
			_, _ = aggregate.Write(digest[:])
			role := "tokenizer"
			if name == "config.json" {
				role = "config"
			}
			artifact := promptcontract.Artifact{Path: name, Role: role, SizeBytes: int64(len(value)), SHA256: hex.EncodeToString(digest[:])}
			artifacts = append(artifacts, artifact)
			versionFiles = append(versionFiles, store.ModelVersionFile{Path: name, Role: role, SizeBytes: artifact.SizeBytes, SHA256: artifact.SHA256})
			files["/"+model+"/v1/"+name] = value
			total += int64(len(value))
		}
		contract, err := promptcontract.ContractID(artifacts, promptcontract.CurrentVersions())
		if err != nil {
			t.Fatal(err)
		}
		weight := hex.EncodeToString(aggregate.Sum(nil))
		entry := &store.ModelRegistryEntry{ID: model, DisplayName: model, Status: "active", Capabilities: []string{"chat"},
			MaxContextLength: 8192, MaxOutputLength: 128, RequiredProviderCapabilities: []string{}}
		version := &store.ModelVersion{ModelID: model, Version: "v1", R2Prefix: model + "/v1", AggregateSHA256: weight,
			TotalSizeBytes: total, FileCount: len(artifacts), Status: "ready"}
		if err := memory.SetModelVersion(entry, version, versionFiles); err != nil {
			t.Fatal(err)
		}
		if err := memory.PromoteModelVersion(model, "v1"); err != nil {
			t.Fatal(err)
		}
		f.models, f.ids = append(f.models, model), append(f.ids, contract)
		weights[model] = weight
		models = append(models, failoverModelSpec{ID: model})
	}
	base, _ := url.Parse("https://preload-capacity.invalid/")
	artifactRoot := filepath.Join(root, "artifacts")
	cache, err := promptcontract.NewArtifactCache(promptcontract.ArtifactCacheConfig{Root: artifactRoot, BaseURL: base,
		DownloadTimeout: 3 * time.Second, HTTPClient: &http.Client{Transport: capacityActualRoundTrip(func(r *http.Request) (*http.Response, error) {
			value, ok := files[r.URL.Path]
			if r.Method != http.MethodGet || r.URL.Scheme != "https" || r.URL.Host != "preload-capacity.invalid" || !ok {
				return nil, errors.New("fixture forbids external artifact IO")
			}
			return &http.Response{StatusCode: http.StatusOK, Header: make(http.Header), Request: r,
				ContentLength: int64(len(value)), Body: io.NopCloser(bytes.NewReader(value))}, nil
		})}})
	if err != nil {
		t.Fatal(err)
	}
	f.provisioner, err = promptcontract.NewProvisioner(ctx, cache, promptcontract.ProvisionerConfig{MaxConcurrent: 2, MaxModels: 9})
	if err != nil {
		t.Fatal(err)
	}
	f.supervisor = promptcontract.NewSupervisor(promptcontract.SupervisorConfig{Enabled: true, BinaryPath: binary,
		SocketPath: f.socket, ArtifactRoot: artifactRoot, MaxConcurrency: 2, MaxConnections: 8, MaxLoadedContracts: 8,
		MaxTokens: 8192, MemoryLimitMiB: 1024, RequestTimeout: 2 * time.Second, PreloadTimeout: 5 * time.Second,
		StartupTimeout: 5 * time.Second, HealthTimeout: time.Second, HealthInterval: 20 * time.Millisecond, ShutdownTimeout: 3 * time.Second})
	f.controller, err = promptcontract.NewPreloadController(f.provisioner, f.supervisor,
		promptcontract.PreloadControllerConfig{PollInterval: 20 * time.Millisecond, MetricsInterval: time.Hour})
	if err != nil {
		t.Fatal(err)
	}
	server.SetPromptArtifactProvisioner(f.provisioner)
	server.SetPromptContractClient(f.supervisor.Client())
	server.SetPromptPreloadController(f.controller) // Production callback installation precedes Start.
	server.SetPromptSupervisor(f.supervisor)
	configureCachePreparationTest(t, reg)
	f.provider = startFailoverProvider(t, ctx, transport, reg, failoverProviderConfig{
		Name: "capacity-provider", Version: "0.8.10", DecodeTPS: 100, Models: models,
		Script: func(ctx context.Context, fp *failoverProvider, request protocol.InferenceRequestMessage, body []byte) {
			var input struct {
				Model string `json:"model"`
			}
			if err := json.Unmarshal(body, &input); err != nil {
				t.Error(err)
				return
			}
			fp.serveFull(ctx, request, input.Model, markerFor(fp.name))
		}})
	setPrefixCacheProtocol(t, reg, f.provider, 1)
	reg.UpdateModelWeightHashes(f.provider.registryID, weights)
	server.server.SyncModelCatalog() // Real Store -> catalog -> full Provisioner handoff.
	awaitCondition(t, 5*time.Second, func() bool {
		s := f.provisioner.Snapshot()
		return s.Counts.Ready == 9 && s.Counts.Pending == 0 && s.Counts.Failed == 0
	}, "nine fixture artifacts were not genuinely verified")
	f.supervisor.Start(ctx)
	awaitCondition(t, 5*time.Second, func() bool { return f.supervisor.Status().Running && f.supervisor.Client().Health(ctx) == nil }, "real Rust service did not become live")
	wire := &http.Transport{DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, "unix", f.socket)
	}}
	t.Cleanup(wire.CloseIdleConnections)
	f.control = &http.Client{Transport: wire, Timeout: 5 * time.Second}
	return f
}

func (f *capacityActualFixture) close(t *testing.T) {
	t.Helper()
	f.closed.Do(func() {
		f.cancel()
		if f.provider != nil {
			f.provider.close()
			select {
			case <-f.provider.done:
			case <-time.After(5 * time.Second):
				t.Error("owned fake provider remained after cancellation and close")
			}
		}
		if f.control != nil {
			f.control.CloseIdleConnections()
		}
		if f.controller != nil {
			f.controller.Close()
		}
		if f.provisioner != nil {
			f.provisioner.Close()
		}
		if f.supervisor != nil {
			f.supervisor.Close()
			if f.supervisor.Status().Running {
				t.Error("owned sidecar remains after Close")
			}
			if _, err := os.Lstat(f.socket); !os.IsNotExist(err) {
				t.Errorf("owned sidecar socket remains: %v", err)
			}
		}
		if f.server != nil {
			f.server.Close()
		}
		capacityVerifyBinary(t, f.binary, f.digest)
	})
}

func (f *capacityActualFixture) metrics(t *testing.T) promptcontract.SidecarStatus {
	t.Helper()
	status, err := f.supervisor.Client().Metrics(f.ctx)
	if err != nil || status.MaxLoadedContracts != 8 || status.LoadedContracts > 8 {
		t.Fatalf("real capacity changed: %+v %v", status, err)
	}
	return status
}

func (f *capacityActualFixture) request(t *testing.T, index int) {
	t.Helper()
	body, _ := json.Marshal(map[string]any{"model": f.models[index], "max_tokens": 32,
		"messages": []map[string]string{{"role": "user", "content": strings.Repeat("hello ", 300)}}})
	got := postAndCapture(t, f.ctx, f.http, f.provider, "/v1/chat/completions", "test-key", string(body))
	var decoded struct {
		Model string `json:"model"`
	}
	if json.Unmarshal(got, &decoded) != nil || decoded.Model != f.models[index] {
		t.Fatal("final-resolved encrypted provider identity changed")
	}
}
