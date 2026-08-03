package e2e

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/stretchr/testify/require"

	"github.com/eigeninference/d-inference/coordinator/promptcontract"
	"github.com/eigeninference/d-inference/coordinator/protocol"
	"github.com/eigeninference/d-inference/coordinator/registry"
	"github.com/eigeninference/d-inference/e2e/testbed"
)

type exactCacheArtifactFixture struct {
	manifest promptcontract.Manifest
	files    map[string][]byte
}

func TestIntegrationExactCacheRouting(t *testing.T) {
	if testing.Short() {
		t.Skip("requires the real Swift provider and local MLX checkpoint")
	}
	model := exactCacheRoutingTestModelID()
	suite := testbed.NewSuite(testbed.SuiteConfig{
		ModelSpecs:                 []testbed.ModelSpec{{ModelID: model, NumProviders: 2}},
		NumUsers:                   2,
		EnableEphemeralPrefixCache: true,
	})
	require.NoError(t, suite.Start(context.Background()))
	t.Cleanup(suite.Stop)

	providers := liveProviders(suite.Coordinator.Registry)
	require.Len(t, providers, 2)
	// Warm the non-owner first, then the owner last. Debug providers use
	// process-ephemeral cache keys, so the final owner must establish the shared
	// test host's on-disk binding before it donates.
	providers[0].Mu().Lock()
	providers[0].Status = registry.StatusUntrusted
	providers[0].Mu().Unlock()
	require.NoError(t, suite.Coordinator.Registry.SendLoadModel(providers[1].ID, model))
	secondModel := waitForLoadedModel(t, providers[1], model, 3*time.Minute)
	providers[1].Mu().Lock()
	providers[1].Status = registry.StatusUntrusted
	providers[1].Mu().Unlock()
	providers[0].Mu().Lock()
	providers[0].Status = registry.StatusOnline
	providers[0].Mu().Unlock()
	require.NoError(t, suite.Coordinator.Registry.SendLoadModel(providers[0].ID, model))
	firstModel := waitForLoadedModel(t, providers[0], model, 3*time.Minute)
	require.Equal(t, firstModel.WeightHash, secondModel.WeightHash)
	require.Eventually(t, func() bool {
		for _, provider := range providers {
			provider.Mu().Lock()
			_, advertised := provider.PrefixCacheV2Models[model]
			provider.Mu().Unlock()
			if !advertised {
				return false
			}
		}
		return true
	}, 30*time.Second, 100*time.Millisecond,
		"contiguous frozen-full hybrid slots did not advertise after SSD scan readiness")

	fixture := loadExactCacheArtifacts(t, model, firstModel.WeightHash)
	contractArtifacts, err := promptcontract.PromptArtifacts(fixture.manifest.Files)
	require.NoError(t, err)
	contractID, err := promptcontract.ContractID(
		contractArtifacts, promptcontract.CurrentVersions())
	require.NoError(t, err)
	for _, provider := range providers {
		provider.Mu().Lock()
		capability := provider.PrefixCacheV2Models[model]
		provider.Mu().Unlock()
		require.Equal(t, contractID, capability.PromptContractID)
		require.Equal(t, firstModel.WeightHash, capability.ModelAggregateHash)
	}

	artifactServer := httptest.NewServer(http.HandlerFunc(func(
		w http.ResponseWriter, request *http.Request,
	) {
		name := strings.TrimPrefix(request.URL.Path, "/artifacts/")
		body, ok := fixture.files[name]
		if !ok || name == request.URL.Path {
			http.NotFound(w, request)
			return
		}
		w.Header().Set("Content-Length", fmt.Sprint(len(body)))
		_, _ = w.Write(body)
	}))
	t.Cleanup(artifactServer.Close)
	baseURL, err := url.Parse(artifactServer.URL)
	require.NoError(t, err)

	root := exactCacheTempRoot(t)
	artifactRoot := filepath.Join(root, "contracts")
	socketPath := filepath.Join(root, "prompt-sidecar.sock")
	cache, err := promptcontract.NewArtifactCache(promptcontract.ArtifactCacheConfig{
		Root:      artifactRoot,
		BaseURL:   baseURL,
		AllowHTTP: true,
	})
	require.NoError(t, err)
	provisioner, err := promptcontract.NewProvisioner(
		suite.Ctx, cache, promptcontract.ProvisionerConfig{
			MaxConcurrent: 1,
			MaxModels:     1,
		})
	require.NoError(t, err)
	fixture.manifest.R2Prefix = "artifacts"
	require.NoError(t, provisioner.Reconcile([]promptcontract.Manifest{fixture.manifest}))
	waitForProvisionedContract(t, provisioner, model, contractID)

	sidecarBinary := exactCacheSidecarBinary(t)
	supervisorConfig := promptcontract.SupervisorConfig{
		Enabled:            true,
		BinaryPath:         sidecarBinary,
		SocketPath:         socketPath,
		ArtifactRoot:       artifactRoot,
		RequestTimeout:     time.Second,
		HeaderReadTimeout:  time.Second,
		StartupTimeout:     10 * time.Second,
		HealthInterval:     time.Second,
		ShutdownTimeout:    5 * time.Second,
		RestartBackoffMin:  50 * time.Millisecond,
		RestartBackoffMax:  time.Second,
		MaxBodyBytes:       4 << 20,
		MaxConcurrency:     2,
		MaxConnections:     8,
		MaxLoadedContracts: 2,
		MaxTokens:          64 << 10,
		MemoryLimitMiB:     1024,
	}
	supervisor := promptcontract.NewSupervisor(supervisorConfig)
	supervisor.Start(suite.Ctx)
	t.Cleanup(supervisor.Close)
	waitForSidecarLive(t, supervisor, 15*time.Second)
	preloader, err := promptcontract.NewPreloadController(
		provisioner,
		supervisor,
		promptcontract.PreloadControllerConfig{PollInterval: 50 * time.Millisecond},
	)
	require.NoError(t, err)
	preloader.Start(suite.Ctx)
	t.Cleanup(preloader.Close)

	suite.Coordinator.Server.SetPromptArtifactProvisioner(provisioner)
	suite.Coordinator.Server.SetPromptContractClient(supervisor.Client())
	suite.Coordinator.Server.SetPromptPreloadController(preloader)
	waitForPreloadedContract(t, preloader, contractID, 30*time.Second)
	suite.Coordinator.Registry.SetModelCatalog([]registry.CatalogEntry{{
		ID: model, WeightHash: firstModel.WeightHash,
	}})
	require.NoError(t, suite.Coordinator.Registry.ConfigureCacheRouting(
		registry.CacheRoutingConfig{
			Mode:            registry.CacheRoutingOn,
			ActivationPct:   100,
			TTL:             10 * time.Minute,
			MaxHolders:      4,
			MaxDiscountMs:   1_000,
			MaxCostFraction: .35,
			MasterKey:       "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY",
		}))

	lifecycleBefore := suite.Coordinator.Registry.CacheRoutingLifecycleStatus()
	prompt := longExactCachePrompt()
	first := postExactCacheChat(t, suite, suite.Users[0].APIKey, model, prompt)
	require.Zero(t, first.cachedTokens, "first request must prefill cold before donation")
	require.Eventually(t, func() bool {
		_, attempts := suite.Coordinator.Registry.CacheRoutingStateCounts()
		return attempts > 0
	}, 5*time.Second, 100*time.Millisecond,
		"first request did not enter the provider-confirmed cache protocol")
	require.Eventually(t, func() bool {
		holders, _ := suite.Coordinator.Registry.CacheRoutingStateCounts()
		return holders > 0
	}, 2*time.Minute, 250*time.Millisecond,
		"durable frozen-full donation did not publish a reusable cache holder")
	require.Eventually(t, func() bool {
		lifecycle := suite.Coordinator.Registry.CacheRoutingLifecycleStatus()
		return lifecycle.SSDLookups > lifecycleBefore.SSDLookups &&
			lifecycle.SSDMisses > lifecycleBefore.SSDMisses &&
			lifecycle.SSDDonations > lifecycleBefore.SSDDonations
	}, 2*time.Minute, 250*time.Millisecond,
		"miss and donation lifecycle telemetry did not advance")

	// The lifecycle struct is filled from two transports with very different
	// latencies, and the wait above only synchronises one of them.
	// SSDLookups / SSDMisses / SSDDonations come from the immediate
	// `prefix_cache_ready_v2` push, so they are current the instant the
	// donation settles. DonationOutcomes rides the periodic provider
	// heartbeat instead, so the donation just counted still has its outcome
	// in flight here. Left undrained it lands inside the exact-equality
	// window below and reads as the protocol-v1 provider entering the
	// exact-cache lifecycle, when it is really late telemetry for the v2
	// owner's donation. Drain it BEFORE the downgrade below rather than
	// after: that downgrade is a direct write onto the registry copy, and
	// the next heartbeat from that provider re-asserts its real v2
	// capabilities over it, so the window between downgrade and assertion
	// must stay shorter than one heartbeat.
	settleCacheRoutingTelemetry(t, suite.Coordinator.Registry)

	// Bring the second provider into the candidate set as a protocol-v1 peer.
	// Force one real request through it to prove a mixed v1/v2 fleet keeps the
	// v1 provider available for ordinary cold inference without cache hints.
	stabilizeExactCacheRoutingCosts(providers, model)
	providers[1].Mu().Lock()
	providers[1].PrefixCacheProtocol = 1
	providers[1].PrefixCacheV2Models = nil
	providers[1].Status = registry.StatusOnline
	providers[1].Mu().Unlock()
	providers[0].Mu().Lock()
	providers[0].Status = registry.StatusUntrusted
	providers[0].Mu().Unlock()
	mixedLifecycleBefore := suite.Coordinator.Registry.CacheRoutingLifecycleStatus()
	mixedV1 := postExactCacheChat(
		t, suite, suite.Users[0].APIKey, model,
		"Serve this request through the protocol-v1 cold fallback provider.")
	require.NotEmpty(t, mixedV1.content)
	require.Zero(t, mixedV1.cachedTokens)
	require.Equal(t, providers[1].ID, mixedV1.providerID,
		"forced mixed-fleet request did not use the protocol-v1 provider")
	require.Equal(t, mixedLifecycleBefore,
		suite.Coordinator.Registry.CacheRoutingLifecycleStatus(),
		"protocol-v1 cold fallback unexpectedly entered the exact-cache lifecycle")
	providers[0].Mu().Lock()
	providers[0].Status = registry.StatusOnline
	providers[0].Mu().Unlock()

	// Provider-confirmed evidence must keep the repeated request on the v2 owner
	// and preserve exact deterministic output through frozen-full adoption.
	second := postExactCacheChat(t, suite, suite.Users[0].APIKey, model, prompt)
	require.Positive(t, second.cachedTokens)
	require.Equal(t, first.content, second.content)
	require.Eventually(t, func() bool {
		return suite.Coordinator.Registry.CacheRoutingLifecycleStatus().SSDHits >
			lifecycleBefore.SSDHits
	}, 30*time.Second, 100*time.Millisecond,
		"positive cache hit lifecycle telemetry did not advance")

	isolated := postExactCacheChat(t, suite, suite.Users[1].APIKey, model, prompt)
	require.Zero(t, isolated.cachedTokens,
		"a different authenticated account crossed the cache-scope boundary")

	// Sidecar loss is never an inference outage. Stop the real supervised
	// process, serve cold through the closed client, then restore a fresh
	// supervisor over the same verified artifact directory.
	preloader.Close()
	supervisor.Close()
	outage := postExactCacheChat(
		t, suite, suite.Users[0].APIKey, model,
		"Serve this request while exact prompt planning is unavailable.")
	require.NotEmpty(t, outage.content)
	restartedSupervisor := promptcontract.NewSupervisor(supervisorConfig)
	restartedSupervisor.Start(suite.Ctx)
	t.Cleanup(restartedSupervisor.Close)
	waitForSidecarLive(t, restartedSupervisor, 15*time.Second)
	restartedPreloader, err := promptcontract.NewPreloadController(
		provisioner,
		restartedSupervisor,
		promptcontract.PreloadControllerConfig{PollInterval: 50 * time.Millisecond},
	)
	require.NoError(t, err)
	restartedPreloader.Start(suite.Ctx)
	t.Cleanup(restartedPreloader.Close)
	suite.Coordinator.Server.SetPromptContractClient(restartedSupervisor.Client())
	suite.Coordinator.Server.SetPromptPreloadController(restartedPreloader)
	waitForPreloadedContract(t, restartedPreloader, contractID, 30*time.Second)
	restored := postExactCacheChat(t, suite, suite.Users[0].APIKey, model, prompt)
	require.Positive(t, restored.cachedTokens, "exact-cache routing did not reopen after re-preload")

	// A live disconnect still leaves ordinary cold serving available.
	suite.Coordinator.Registry.Disconnect(providers[0].ID)
	require.Eventually(t, func() bool {
		return len(liveProviders(suite.Coordinator.Registry)) >= 2
	}, 20*time.Second, 100*time.Millisecond,
		"a protocol-v2 provider with no currently ready cache model failed to reconnect cold")
	fallback := postExactCacheChat(t, suite, suite.Users[0].APIKey, model, prompt+" diverged")
	require.NotEmpty(t, fallback.content)
}

func exactCacheRoutingTestModelID() string {
	if modelID := os.Getenv("DARKBLOOM_EXACT_CACHE_TEST_MODEL"); modelID != "" {
		return modelID
	}
	// The ordinary testbed checkpoint (GPT-OSS) deliberately renders the
	// current date and is therefore cold-only. Exact routing needs a stable,
	// CBv2-supported prompt contract.
	return "mlx-community/gemma-4-e2b-it-4bit"
}

type exactCacheResponse struct {
	content      string
	cachedTokens int
	providerID   string
}

func postExactCacheChat(
	t *testing.T,
	suite *testbed.Suite,
	apiKey, model, prompt string,
) exactCacheResponse {
	t.Helper()
	body, err := json.Marshal(map[string]any{
		"model": model,
		"messages": []map[string]string{{
			"role": "user", "content": prompt,
		}},
		"stream": false, "max_tokens": 32, "temperature": 0,
	})
	require.NoError(t, err)
	request, err := http.NewRequestWithContext(
		suite.Ctx,
		http.MethodPost,
		suite.Coordinator.BaseURL()+"/v1/chat/completions",
		bytes.NewReader(body),
	)
	require.NoError(t, err)
	request.Header.Set("Authorization", "Bearer "+apiKey)
	request.Header.Set("Content-Type", "application/json")
	response, err := (&http.Client{Timeout: 5 * time.Minute}).Do(request)
	require.NoError(t, err)
	defer response.Body.Close()
	payload, err := io.ReadAll(response.Body)
	require.NoError(t, err)
	require.Equal(t, http.StatusOK, response.StatusCode, string(payload))
	var decoded struct {
		Choices []struct {
			Message struct {
				Content string `json:"content"`
			} `json:"message"`
		} `json:"choices"`
		Usage struct {
			PromptTokensDetails struct {
				CachedTokens int `json:"cached_tokens"`
			} `json:"prompt_tokens_details"`
		} `json:"usage"`
	}
	require.NoError(t, json.Unmarshal(payload, &decoded))
	require.NotEmpty(t, decoded.Choices)
	return exactCacheResponse{
		content:      decoded.Choices[0].Message.Content,
		cachedTokens: decoded.Usage.PromptTokensDetails.CachedTokens,
		providerID:   response.Header.Get("X-Provider-Id"),
	}
}

func liveProviders(r *registry.Registry) []*registry.Provider {
	var providers []*registry.Provider
	r.ForEachProvider(func(provider *registry.Provider) {
		providers = append(providers, provider)
	})
	return providers
}

func stabilizeExactCacheRoutingCosts(providers []*registry.Provider, model string) {
	for _, provider := range providers {
		provider.Mu().Lock()
		provider.PrefillTPS = 1_000
		provider.DecodeTPS = 100
		provider.SystemMetrics = protocol.SystemMetrics{ThermalState: "nominal"}
		if capacity := provider.BackendCapacity; capacity != nil {
			capacity.GPUMemoryActiveGB = 0
			capacity.GPUMemoryCacheGB = 0
			capacity.GPUMemoryPeakGB = 0
			for index := range capacity.Slots {
				slot := &capacity.Slots[index]
				if slot.Model != model {
					continue
				}
				slot.NumRunning = 0
				slot.NumWaiting = 0
				slot.ActiveTokens = 0
				slot.MaxTokensPotential = 0
				slot.ActiveTokenBudgetUsed = 0
				slot.QueuedTokenBudget = 0
				slot.ObservedPrefillTPS = 1_000
				slot.ObservedDecodeTPS = 100
			}
		}
		provider.Mu().Unlock()
	}
}

// cacheTelemetryHeartbeat is the provider's default heartbeat period
// (`CoordinatorConfig.heartbeatIntervalSecs`, 5s), which is the transport for
// every counter the coordinator cannot observe inline.
const cacheTelemetryHeartbeat = 5 * time.Second

// settleCacheRoutingTelemetry blocks until nothing the coordinator has already
// counted still has telemetry in flight, so a caller may compare two lifecycle
// snapshots for exact equality and read the difference as caused by whatever
// it did in between.
//
// Two conditions, because the struct has two clocks. First, every donation
// receipt the coordinator accepted (SSDDonations, delivered immediately by
// `prefix_cache_ready_v2`) must have its matching outcome reported: the
// provider settles exactly one outcome per donation job, but that count only
// reaches the coordinator on the heartbeat, so outcomes lag receipts by up to
// one heartbeat and can never be fewer. Second, the whole snapshot must then
// hold still for a full heartbeat, which retires any straggler with no
// corresponding receipt.
func settleCacheRoutingTelemetry(t *testing.T, r *registry.Registry) {
	t.Helper()
	const poll = 100 * time.Millisecond
	settled := cacheTelemetryHeartbeat + time.Second
	deadline := time.Now().Add(2 * time.Minute)
	previous := r.CacheRoutingLifecycleStatus()
	unchangedSince := time.Now()
	for {
		time.Sleep(poll)
		current := r.CacheRoutingLifecycleStatus()
		if !reflect.DeepEqual(current, previous) {
			previous, unchangedSince = current, time.Now()
		}
		var reported uint64
		for _, count := range current.DonationOutcomes {
			reported += count
		}
		if reported >= current.SSDDonations &&
			time.Since(unchangedSince) >= settled {
			return
		}
		require.False(t, time.Now().After(deadline),
			"cache-routing lifecycle telemetry never settled: %d donation receipts, "+
				"%d outcomes reported", current.SSDDonations, reported)
	}
}

func waitForLoadedModel(
	t *testing.T,
	provider *registry.Provider,
	model string,
	timeout time.Duration,
) protocol.ModelInfo {
	t.Helper()
	var modelInfo protocol.ModelInfo
	require.Eventually(t, func() bool {
		provider.Mu().Lock()
		defer provider.Mu().Unlock()
		found := false
		for _, candidate := range provider.Models {
			if candidate.ID == model {
				modelInfo = candidate
				found = true
				break
			}
		}
		if !found || provider.BackendCapacity == nil {
			return false
		}
		for _, slot := range provider.BackendCapacity.Slots {
			if slot.Model == model && (slot.State == "running" || slot.State == "idle") {
				return true
			}
		}
		return false
	}, timeout, 500*time.Millisecond)
	return modelInfo
}

func waitForProvisionedContract(
	t *testing.T,
	provisioner *promptcontract.Provisioner,
	model, contractID string,
) {
	t.Helper()
	require.Eventually(t, func() bool {
		status, ok := provisioner.Status(model)
		require.False(t, ok && status.LastError != "", status.LastError)
		return ok && status.ArtifactReady && status.PromptContractID == contractID
	}, 30*time.Second, 100*time.Millisecond)
}

func waitForSidecarLive(
	t *testing.T,
	supervisor *promptcontract.Supervisor,
	timeout time.Duration,
) {
	t.Helper()
	require.Eventually(t, func() bool {
		status := supervisor.Status()
		if !status.Running || status.ChildGeneration == 0 {
			return false
		}
		ctx, cancel := context.WithTimeout(context.Background(), 250*time.Millisecond)
		defer cancel()
		return supervisor.Client().Health(ctx) == nil
	}, timeout, 100*time.Millisecond)
}

func waitForPreloadedContract(
	t *testing.T,
	preloader *promptcontract.PreloadController,
	contractID string,
	timeout time.Duration,
) {
	t.Helper()
	require.Eventually(t, func() bool {
		return preloader.ReadyFor(contractID)
	}, timeout, 100*time.Millisecond, "active contract was not preloaded: %+v", preloader.Status())
}

func exactCacheSidecarBinary(t *testing.T) string {
	t.Helper()
	if configured := os.Getenv("DARKBLOOM_PROMPT_SIDECAR_BINARY"); configured != "" {
		if info, err := os.Stat(configured); err == nil && !info.IsDir() {
			return configured
		}
	}
	root := os.Getenv("DARKBLOOM_REPO_ROOT")
	if root == "" {
		cwd, err := os.Getwd()
		require.NoError(t, err)
		root = filepath.Clean(filepath.Join(cwd, ".."))
	}
	for _, profile := range []string{"release", "debug"} {
		candidate := filepath.Join(
			root, "coordinator", "promptsidecar", "target", profile, "promptsidecar")
		if info, err := os.Stat(candidate); err == nil && !info.IsDir() {
			return candidate
		}
	}
	t.Skip("promptsidecar binary unavailable; build coordinator/promptsidecar first")
	return ""
}

func exactCacheTempRoot(t *testing.T) string {
	t.Helper()
	base, err := filepath.EvalSymlinks("/tmp")
	require.NoError(t, err)
	root, err := os.MkdirTemp(base, "db-exact-")
	require.NoError(t, err)
	t.Cleanup(func() {
		_ = filepath.Walk(root, func(path string, info os.FileInfo, walkErr error) error {
			if walkErr != nil {
				return nil
			}
			if info.IsDir() {
				_ = os.Chmod(path, 0o700)
			} else {
				_ = os.Chmod(path, 0o600)
			}
			return nil
		})
		if removeErr := os.RemoveAll(root); removeErr != nil {
			t.Errorf("remove exact-cache temp root: %v", removeErr)
		}
	})
	return root
}

func loadExactCacheArtifacts(
	t *testing.T,
	model, aggregateHash string,
) exactCacheArtifactFixture {
	t.Helper()
	home, err := os.UserHomeDir()
	require.NoError(t, err)
	modelDir := "models--" + strings.ReplaceAll(model, "/", "--")
	snapshots := filepath.Join(home, ".cache", "huggingface", "hub", modelDir, "snapshots")
	entries, err := os.ReadDir(snapshots)
	require.NoError(t, err)
	var snapshot string
	var newest time.Time
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		info, infoErr := entry.Info()
		require.NoError(t, infoErr)
		if snapshot == "" || info.ModTime().After(newest) {
			snapshot = filepath.Join(snapshots, entry.Name())
			newest = info.ModTime()
		}
	}
	require.NotEmpty(t, snapshot)

	files := make(map[string][]byte)
	var artifacts []promptcontract.Artifact
	var modelType string
	err = filepath.Walk(snapshot, func(path string, info os.FileInfo, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		role := exactCacheArtifactRole(filepath.Base(path))
		if role == "" {
			return nil
		}
		stat, statErr := os.Stat(path)
		if statErr != nil || !stat.Mode().IsRegular() {
			return statErr
		}
		relative, relativeErr := filepath.Rel(snapshot, path)
		if relativeErr != nil {
			return relativeErr
		}
		relative = filepath.ToSlash(relative)
		file, openErr := os.Open(path)
		if openErr != nil {
			return openErr
		}
		hasher := sha256.New()
		_, hashErr := io.Copy(hasher, file)
		closeErr := file.Close()
		if hashErr != nil {
			return hashErr
		}
		if closeErr != nil {
			return closeErr
		}
		artifacts = append(artifacts, promptcontract.Artifact{
			Path: relative, Role: role, SizeBytes: stat.Size(),
			SHA256: hex.EncodeToString(hasher.Sum(nil)),
		})
		if !promptcontract.IsPromptRole(role) {
			return nil
		}
		data, readErr := os.ReadFile(path)
		if readErr != nil {
			return readErr
		}
		files[relative] = data
		if relative == "config.json" {
			var config struct {
				ModelType string `json:"model_type"`
			}
			if json.Unmarshal(data, &config) == nil {
				modelType = config.ModelType
			}
		}
		return nil
	})
	require.NoError(t, err)
	require.NotEmpty(t, modelType)
	require.Contains(t, files, "config.json")
	require.Contains(t, files, "tokenizer.json")
	require.Contains(t, files, "chat_template.jinja")
	sort.Slice(artifacts, func(i, j int) bool {
		if artifacts[i].Path != artifacts[j].Path {
			return artifacts[i].Path < artifacts[j].Path
		}
		return artifacts[i].SHA256 < artifacts[j].SHA256
	})
	aggregate := sha256.New()
	for _, artifact := range artifacts {
		digest, decodeErr := hex.DecodeString(artifact.SHA256)
		require.NoError(t, decodeErr)
		_, _ = aggregate.Write(digest)
	}
	computedAggregate := hex.EncodeToString(aggregate.Sum(nil))
	require.Equal(t, aggregateHash, computedAggregate,
		"Go manifest and Swift provider aggregate hashes diverged")
	return exactCacheArtifactFixture{
		manifest: promptcontract.Manifest{
			ModelID: model, ModelType: modelType,
			AggregateSHA256: computedAggregate, Files: artifacts,
		},
		files: files,
	}
}

func exactCacheArtifactRole(name string) string {
	switch name {
	case "model.safetensors.index.json":
		return "index"
	case "preprocessor_config.json", "processor_config.json":
		return "preprocessor"
	case "tokenizer.json", "tokenizer_config.json", "tokenizer.model",
		"special_tokens_map.json", "added_tokens.json", "vocab.json", "merges.txt":
		return "tokenizer"
	case "config.json", "generation_config.json", "quantize_config.json":
		return "config"
	case "chat_template.jinja", "chat_template.json":
		return "template"
	default:
		if strings.HasSuffix(name, ".safetensors") ||
			strings.HasSuffix(name, ".npz") ||
			strings.HasSuffix(name, ".bin") ||
			name == "weights.npz" {
			return "weight"
		}
		return ""
	}
}

func longExactCachePrompt() string {
	var builder strings.Builder
	// Gemma 4's hybrid attention requires 25,600 recomputation tokens, and the
	// production SSD policy persists only when at least another 1,024 tokens can
	// be reused. Keep this fixture above that real gate so the E2E exercises
	// durable donation rather than merely proving the cold fallback.
	for i := 0; i < 2_600; i++ {
		builder.WriteString(
			"The observatory records stable stellar spectra for deterministic archival retrieval. ")
	}
	return builder.String()
}
