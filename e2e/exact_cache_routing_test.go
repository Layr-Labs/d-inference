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
	for _, provider := range providers {
		provider.Mu().Lock()
		_, advertised := provider.PrefixCacheV2Models[model]
		provider.Mu().Unlock()
		require.False(t, advertised,
			"unsafe hybrid attention layout advertised reusable cache evidence")
	}

	fixture := loadExactCacheArtifacts(t, model, firstModel.WeightHash)
	contractArtifacts, err := promptcontract.PromptArtifacts(fixture.manifest.Files)
	require.NoError(t, err)
	contractID, err := promptcontract.ContractID(
		contractArtifacts, promptcontract.CurrentVersions())
	require.NoError(t, err)

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
	waitForSidecar(t, supervisor, 15*time.Second)

	suite.Coordinator.Server.SetPromptArtifactProvisioner(provisioner)
	suite.Coordinator.Server.SetPromptContractClient(supervisor.Client())
	suite.Coordinator.Registry.SetModelCatalog([]registry.CatalogEntry{{
		ID: model, WeightHash: firstModel.WeightHash,
	}})
	require.NoError(t, suite.Coordinator.Registry.ConfigureCacheRouting(
		registry.CacheRoutingConfig{
			Mode:            registry.CacheRoutingOn,
			TTL:             10 * time.Minute,
			MaxHolders:      4,
			MaxDiscountMs:   1_000,
			MaxCostFraction: .35,
			MasterKey:       "MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY",
		}))

	prompt := longExactCachePrompt()
	first := postExactCacheChat(t, suite, suite.Users[0].APIKey, model, prompt)
	require.Zero(t, first.cachedTokens, "unsafe hybrid model reported a cache hit")
	holders, attempts := suite.Coordinator.Registry.CacheRoutingStateCounts()
	require.Zero(t, holders, "unsafe hybrid model published a reusable cache holder")
	require.Zero(t, attempts, "unsafe hybrid model entered the v2 receipt protocol")

	// Bring the second provider into the candidate set. Current production
	// models interleave sliding and storage-owning full attention, so exact
	// replay requires a full prefill and both providers must remain cold.
	stabilizeExactCacheRoutingCosts(providers, model)
	providers[1].Mu().Lock()
	providers[1].Status = registry.StatusOnline
	providers[1].Mu().Unlock()

	second := postExactCacheChat(t, suite, suite.Users[0].APIKey, model, prompt)
	require.Zero(t, second.cachedTokens,
		"hybrid full-replay policy was misreported as reusable prefix work")

	isolated := postExactCacheChat(t, suite, suite.Users[1].APIKey, model, prompt)
	require.Zero(t, isolated.cachedTokens,
		"a different authenticated account crossed the cache-scope boundary")

	// Sidecar loss is never an inference outage. Stop the real supervised
	// process, serve cold through the closed client, then restore a fresh
	// supervisor over the same verified artifact directory.
	supervisor.Close()
	outage := postExactCacheChat(
		t, suite, suite.Users[0].APIKey, model,
		"Serve this request while exact prompt planning is unavailable.")
	require.NotEmpty(t, outage.content)
	restartedSupervisor := promptcontract.NewSupervisor(supervisorConfig)
	restartedSupervisor.Start(suite.Ctx)
	t.Cleanup(restartedSupervisor.Close)
	waitForSidecar(t, restartedSupervisor, 15*time.Second)
	suite.Coordinator.Server.SetPromptContractClient(restartedSupervisor.Client())

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

func waitForSidecar(
	t *testing.T,
	supervisor *promptcontract.Supervisor,
	timeout time.Duration,
) {
	t.Helper()
	require.Eventually(t, func() bool {
		status := supervisor.Status()
		return status.Running && status.Ready
	}, timeout, 100*time.Millisecond)
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
