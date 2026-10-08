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
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/registry"
)

// Planner responses and provider generation are scripted. The tests use the
// production supervisor/client/preloader, verified artifact cache, HTTP
// inference handler, in-memory store, registry and encrypted WebSocket transport.
func TestPromptDeadlineHelperProcess(t *testing.T) {
	if os.Getenv("DARKBLOOM_PROMPT_DEADLINE_HELPER") != "1" {
		return
	}
	var socket string
	for i, arg := range os.Args {
		if arg == "--socket" && i+1 < len(os.Args) {
			socket = os.Args[i+1]
		}
	}
	listener, err := net.Listen("unix", socket)
	if err != nil {
		os.Exit(2)
	}
	if os.Chmod(socket, 0o600) != nil {
		os.Exit(3)
	}
	countRE := regexp.MustCompile(`fixture_count=(\d+)`)
	delayRE := regexp.MustCompile(`fixture_delay_ms=(\d+)`)
	var plans atomic.Uint64
	server := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/health", "/ready":
			_ = json.NewEncoder(w).Encode(promptcontract.ReadinessStatus{Status: "ok", Ready: true})
		case "/metrics":
			_ = json.NewEncoder(w).Encode(promptcontract.SidecarStatus{Status: "ok", Ready: true,
				LoadedContracts: 1, MaxLoadedContracts: 1, PlanningPermitsAvailable: 32, MaxPlanningConcurrency: 32,
				Metrics: promptcontract.SidecarMetrics{Plans: promptcontract.SidecarPlanMetrics{Started: plans.Load()}}})
		case "/v1/preload":
			var input struct {
				Contracts []string `json:"prompt_contract_ids"`
			}
			_ = json.NewDecoder(r.Body).Decode(&input)
			report := promptcontract.PreloadReport{Status: "ready", Ready: true,
				Requested: len(input.Contracts), Cold: len(input.Contracts)}
			for _, contract := range input.Contracts {
				report.Results = append(report.Results, promptcontract.PreloadResult{PromptContractID: contract, Status: "cold"})
			}
			_ = json.NewEncoder(w).Encode(report)
		case "/v1/plan":
			plans.Add(1)
			var input struct {
				Contract string          `json:"prompt_contract_id"`
				Body     json.RawMessage `json:"body"`
			}
			_ = json.NewDecoder(r.Body).Decode(&input)
			if match := delayRE.FindSubmatch(input.Body); len(match) == 2 {
				ms, _ := strconv.Atoi(string(match[1]))
				select {
				case <-r.Context().Done():
					return
				case <-time.After(time.Duration(ms) * time.Millisecond):
				}
			}
			if strings.Contains(string(input.Body), "fixture_error") {
				http.Error(w, "scripted planner unavailable", http.StatusServiceUnavailable)
				return
			}
			count := uint64(5779)
			if match := countRE.FindSubmatch(input.Body); len(match) == 2 {
				count, _ = strconv.ParseUint(string(match[1]), 10, 64)
			}
			if strings.Contains(string(input.Body), "fixture_wrong_contract") {
				input.Contract = strings.Repeat("f", 64)
			}
			plan := promptcontract.Plan{PromptContractID: input.Contract, PromptTokenCount: uint32(count)}
			if count > 0 {
				hash := strings.Repeat("a", 64)
				for block := uint32(1); uint64(block)*uint64(promptcontract.BlockSize) < count; block++ {
					plan.BlockBoundaries = append(plan.BlockBoundaries, promptcontract.Boundary{TokenCount: block * promptcontract.BlockSize, ChainHash: hash})
					plan.LastCompleteBlockHash = &hash
				}
			}
			_ = json.NewEncoder(w).Encode(plan)
		default:
			http.NotFound(w, r)
		}
	})}
	_ = server.Serve(listener)
	os.Exit(0)
}

type promptDeadlineFixture struct {
	model, hash, contract string
	supervisor            *promptcontract.Supervisor
}

func newPromptDeadlineFixture(t testing.TB, s *serverFixture) promptDeadlineFixture {
	t.Helper()
	base, err := filepath.EvalSymlinks("/tmp")
	if err != nil {
		t.Fatal(err)
	}
	root, err := os.MkdirTemp(base, "prompt-deadline-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
			if err == nil && info.Mode()&os.ModeSymlink == 0 {
				return os.Chmod(path, 0o700)
			}
			return err
		})
		_ = os.RemoveAll(root)
	})
	payload := []byte(`{"version":"1.0"}`)
	digest := sha256.Sum256(payload)
	aggregate := sha256.Sum256(digest[:])
	f := promptDeadlineFixture{model: "prompt-deadline-fixture", hash: hex.EncodeToString(aggregate[:])}
	files := []promptcontract.Artifact{{Path: "tokenizer.json", Role: "tokenizer", SizeBytes: int64(len(payload)), SHA256: hex.EncodeToString(digest[:])}}
	f.contract, err = promptcontract.ContractID(files, promptcontract.CurrentVersions())
	if err != nil {
		t.Fatal(err)
	}
	origin := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { _, _ = w.Write(payload) }))
	t.Cleanup(origin.Close)
	baseURL, _ := url.Parse(origin.URL)
	cache, err := promptcontract.NewArtifactCache(promptcontract.ArtifactCacheConfig{
		Root: filepath.Join(root, "artifacts"), BaseURL: baseURL, HTTPClient: origin.Client(), AllowHTTP: true})
	if err != nil {
		t.Fatal(err)
	}
	provisioner, err := promptcontract.NewProvisioner(context.Background(), cache, promptcontract.ProvisionerConfig{MaxConcurrent: 1, MaxModels: 1})
	if err != nil {
		t.Fatal(err)
	}
	s.SetPromptArtifactProvisioner(provisioner)
	s.registry.SetModelCatalog([]registry.CatalogEntry{{ID: f.model, WeightHash: f.hash}})
	if err := provisioner.Reconcile([]promptcontract.Manifest{{ModelID: f.model, R2Prefix: "models/fixture", AggregateSHA256: f.hash, Files: files}}); err != nil {
		t.Fatal(err)
	}
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	script := filepath.Join(root, "helper")
	if err := os.WriteFile(script, []byte("#!/bin/sh\nexec \""+executable+"\" -test.run=TestPromptDeadlineHelperProcess -- \"$@\"\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("DARKBLOOM_PROMPT_DEADLINE_HELPER", "1")
	f.supervisor = promptcontract.NewSupervisor(promptcontract.SupervisorConfig{Enabled: true,
		BinaryPath: script, SocketPath: filepath.Join(root, "run", "prompt.sock"), ArtifactRoot: filepath.Join(root, "artifacts"),
		RequestTimeout: time.Second, StartupTimeout: 5 * time.Second, HealthTimeout: time.Second,
		HealthInterval: 20 * time.Millisecond, ShutdownTimeout: time.Second})
	t.Cleanup(f.supervisor.Close)
	controller, err := promptcontract.NewPreloadController(provisioner, f.supervisor, promptcontract.PreloadControllerConfig{PollInterval: 10 * time.Millisecond})
	if err != nil {
		t.Fatal(err)
	}
	s.SetPromptContractClient(f.supervisor.Client())
	s.SetPromptPreloadController(controller)
	t.Cleanup(controller.Close)
	f.supervisor.Start(context.Background())
	limit := time.Now().Add(10 * time.Second)
	for time.Now().Before(limit) && !f.supervisor.Status().Ready {
		time.Sleep(5 * time.Millisecond)
	}
	controller.Start(context.Background())
	for time.Now().Before(limit) {
		if controller.ReadyFor(f.contract) {
			return f
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("synthetic planner never ready: %+v / %+v", f.supervisor.Status(), controller.Status())
	return f
}
